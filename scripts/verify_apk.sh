#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — verify the CONTENTS of a built Android APK.
#
# WHY THIS EXISTS
#
# CI used to assert only that `flutter build apk` exited 0. An exit code cannot
# see inside the artifact, so two whole classes of shipping bug walked straight
# through a green build:
#
#   1. A cargokit/Gradle regression that silently drops (or produces a stub)
#      lib/<abi>/libliberated_bread_core.so. Gradle happily packages an APK
#      without it, the build is green, and the app dies on the first FFI call
#      with "Failed to lookup symbol" on a user's phone. This was found by hand
#      with `unzip -l`; that manual step is now this script.
#   2. A merged-manifest regression — a plugin upgrade, a manifest edit, or a
#      manifest-merger conflict resolution that drops BLUETOOTH_SCAN /
#      BLUETOOTH_CONNECT / ACCESS_FINE_LOCATION / INTERNET, or changes the
#      applicationId. The APK still installs; every BLE scan then fails at
#      runtime, and an applicationId change orphans every existing install.
#
# Both checks read the artifact, so both can genuinely fail. Run it locally the
# same way CI does (the scripts/test.sh pattern):
#
#   ./scripts/verify_apk.sh build/app/outputs/flutter-apk/app-debug.apk \
#     --require-abis arm64-v8a,armeabi-v7a,x86,x86_64
#
# Usage:
#   ./scripts/verify_apk.sh <path-to-apk> [options]
#
# Options:
#   --require-abis a,b,c   ABIs that MUST be present (default: arm64-v8a).
#                          Beyond these, EVERY ABI the build actually produced
#                          is verified — the flag only pins the floor, because
#                          debug and release builds legitimately ship different
#                          ABI sets (release drops x86).
#   --min-so-bytes N       Size floor for libliberated_bread_core.so
#                          (default: 65536).
#
# Environment:
#   AAPT2                  Explicit path to aapt2. Otherwise it is looked up on
#                          PATH, then under $ANDROID_HOME / $ANDROID_SDK_ROOT
#                          build-tools (highest version wins).

set -euo pipefail

# The cdylib cargokit builds from rust/Cargo.toml. The name is load-bearing:
# [lib] name = "liberated_bread_core", and Dart looks the library up by exactly
# this file name at runtime.
RUST_LIB="libliberated_bread_core.so"
EXPECTED_PACKAGE="ca.pigscanfly.liberatedbread"

# The permissions the app's own code actually needs, so this list fails if one
# is dropped rather than merely documenting the manifest:
#   INTERNET               Home Assistant companion registration + webhooks
#   BLUETOOTH_SCAN         flutter_blue_plus scan on API 31+
#   BLUETOOTH_CONNECT      GATT connect on API 31+
#   ACCESS_FINE_LOCATION   BLE scan on API 30 and below (minSdk is 21)
REQUIRED_PERMISSIONS=(
  "android.permission.INTERNET"
  "android.permission.BLUETOOTH_SCAN"
  "android.permission.BLUETOOTH_CONNECT"
  "android.permission.ACCESS_FINE_LOCATION"
)

# Size floor for the Rust library. A successful build is far above this — the
# debug .so is 1.5-3.1 MB per ABI — while a release .so is much smaller because
# rust/Cargo.toml's release profile sets opt-level = "z", thin LTO and
# strip = "symbols". 64 KiB sits well under any genuine build and well over the
# 0-byte or few-KB file a broken link/strip step leaves behind, which is the
# failure mode this is here to catch.
MIN_SO_BYTES=65536

# arm64-v8a is the only ABI every shipping device needs, so it is the default
# floor. CI passes the full expected set per build type.
REQUIRE_ABIS="arm64-v8a"

APK=""

log()  { printf '\033[1;32m[verify-apk]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[verify-apk]\033[0m %s\n' "$*"; }

# Failures accumulate instead of aborting on the first one: when an APK is
# broken it is far more useful to see "the .so is missing for 3 ABIs AND
# BLUETOOTH_SCAN was dropped" in a single CI run than to fix them one per push.
FAILURES=0
fail() {
  printf '\033[1;31m[verify-apk] FAIL:\033[0m %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

usage() {
  cat <<'EOF'
Usage: verify_apk.sh <path-to-apk> [options]

Options:
  --require-abis a,b,c   ABIs that MUST be present (default: arm64-v8a).
                         Every ABI the build actually produced is verified on
                         top of these; the flag only pins the floor, because
                         debug and release builds ship different ABI sets.
  --min-so-bytes N       Size floor for libliberated_bread_core.so (default: 65536).

Environment:
  AAPT2                  Explicit path to aapt2. Otherwise PATH, then
                         $ANDROID_HOME / $ANDROID_SDK_ROOT build-tools.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-abis)
      [[ $# -ge 2 ]] || { echo "--require-abis needs a value" >&2; exit 2; }
      REQUIRE_ABIS="$2"; shift 2 ;;
    --min-so-bytes)
      [[ $# -ge 2 ]] || { echo "--min-so-bytes needs a value" >&2; exit 2; }
      MIN_SO_BYTES="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$APK" ]] || { echo "Only one APK path may be given" >&2; exit 2; }
      APK="$1"; shift ;;
  esac
done

if [[ -z "$APK" ]]; then
  echo "Usage: $0 <path-to-apk> [--require-abis a,b,c] [--min-so-bytes N]" >&2
  exit 2
fi

# Guard the path itself. A workflow typo in the APK path would otherwise make
# every check below vacuously "pass nothing", which is how a verifier quietly
# stops verifying.
if [[ ! -f "$APK" ]]; then
  fail "APK not found: $APK"
  exit 1
fi
if [[ ! -s "$APK" ]]; then
  fail "APK is empty (0 bytes): $APK"
  exit 1
fi

command -v unzip >/dev/null 2>&1 || { echo "unzip is required but not installed" >&2; exit 2; }

# ── locate aapt2 ────────────────────────────────────────────────────────────
# The GitHub runner installs build-tools;34.0.0 but does not reliably put it on
# PATH, and a local dev box has its SDK wherever setup.sh put it. Search, in
# order: explicit $AAPT2, PATH, then the highest build-tools under the SDK root.
find_aapt2() {
  if [[ -n "${AAPT2:-}" ]]; then
    [[ -x "$AAPT2" ]] || return 1
    printf '%s\n' "$AAPT2"; return 0
  fi
  if command -v aapt2 >/dev/null 2>&1; then
    command -v aapt2; return 0
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [[ -n "$sdk" && -d "$sdk/build-tools" ]] || return 1
  local listing sorted v
  listing="$(ls -1 "$sdk/build-tools" 2>/dev/null || true)"
  [[ -n "$listing" ]] || return 1
  # Highest build-tools version wins. `sort -V` is GNU-only, so fall back to a
  # lexical sort on BSD/macOS rather than silently picking the oldest.
  sorted="$(printf '%s\n' "$listing" | sort -Vr 2>/dev/null)" \
    || sorted="$(printf '%s\n' "$listing" | sort -r)"
  while read -r v; do
    if [[ -x "$sdk/build-tools/$v/aapt2" ]]; then
      printf '%s\n' "$sdk/build-tools/$v/aapt2"
      return 0
    fi
  done <<< "$sorted"
  return 1
}

AAPT2_BIN="$(find_aapt2 || true)"

log "Verifying $APK ($(du -h "$APK" | cut -f1))"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! unzip -l "$APK" > "$WORK/listing.txt" 2>"$WORK/unzip.err"; then
  fail "Not a readable zip/APK: $APK"
  cat "$WORK/unzip.err" >&2
  exit 1
fi

if ! grep -q ' AndroidManifest\.xml$' "$WORK/listing.txt"; then
  fail "No AndroidManifest.xml entry — this file is not an APK: $APK"
  exit 1
fi

# ── 1. native library payload ───────────────────────────────────────────────
# `unzip -l` prints "Length Date Time Name"; entries under lib/ never contain
# spaces, so field 4 is the whole path.
awk '$1 ~ /^[0-9]+$/ && $4 ~ /^lib\/[^\/]+\/[^\/]+\.so$/ { print $1 "\t" $4 }' \
  "$WORK/listing.txt" > "$WORK/libs.tsv"
awk -F'\t' '{ split($2, p, "/"); print p[2] }' "$WORK/libs.tsv" | sort -u > "$WORK/abis.txt"

entry_size() {
  # Echoes the packaged (uncompressed) size of an entry, or nothing if absent.
  awk -F'\t' -v want="$1" '$2 == want { print $1 }' "$WORK/libs.tsv"
}

log "Native libraries in the APK:"
if [[ -s "$WORK/libs.tsv" ]]; then
  # Sorted by path so the log reads as a stable per-ABI table run over run.
  sort -k2 "$WORK/libs.tsv" | awk -F'\t' '{ printf "  %10d  %s\n", $1, $2 }'
else
  echo "  (none)"
fi

if [[ ! -s "$WORK/abis.txt" ]]; then
  fail "APK contains no lib/<abi>/ directory at all — the native build produced nothing."
fi

while read -r abi; do
  [[ -n "$abi" ]] || continue
  rust_size="$(entry_size "lib/$abi/$RUST_LIB")"
  flutter_size="$(entry_size "lib/$abi/libflutter.so")"

  if [[ -z "$rust_size" ]]; then
    if [[ -n "$flutter_size" ]]; then
      # The exact signature of the cargokit regression this script exists for:
      # Flutter's own engine made it into the ABI slice, ours did not.
      fail "lib/$abi/$RUST_LIB is MISSING while lib/$abi/libflutter.so is present" \
           "— cargokit did not package the Rust library for $abi."
    else
      fail "lib/$abi/$RUST_LIB is MISSING (and so is libflutter.so for $abi)."
    fi
  elif [[ "$rust_size" -lt "$MIN_SO_BYTES" ]]; then
    fail "lib/$abi/$RUST_LIB is only ${rust_size} bytes (floor ${MIN_SO_BYTES}) — a stub or truncated link output, not a real build."
  else
    log "  ok  lib/$abi/$RUST_LIB (${rust_size} bytes)"
  fi

  # Not fatal: a missing libflutter.so is a Flutter-tooling problem rather than
  # the Rust-packaging regression this script targets, but it should be loud.
  if [[ -z "$flutter_size" ]]; then
    warn "lib/$abi/libflutter.so is missing — is $abi a real Flutter ABI slice?"
  fi
done < "$WORK/abis.txt"

# The ABI set differs by build type (release drops x86), so the caller pins the
# floor and we verify everything actually produced on top of that.
IFS=',' read -r -a required_abis <<< "$REQUIRE_ABIS"
for abi in "${required_abis[@]}"; do
  [[ -n "$abi" ]] || continue
  if ! grep -qx "$abi" "$WORK/abis.txt"; then
    fail "Required ABI '$abi' is absent from the APK (found: $(tr '\n' ' ' < "$WORK/abis.txt"))."
  fi
done

# ── 2. merged manifest: package id + permissions ────────────────────────────
# Reads the *merged* manifest out of the built APK, not the source manifest, so
# it also covers permissions a plugin injects or a merger conflict removes.
if [[ -z "$AAPT2_BIN" ]]; then
  fail "aapt2 not found — cannot verify the merged manifest. Set \$AAPT2 or \$ANDROID_HOME (build-tools must be installed)."
else
  log "Using aapt2: $AAPT2_BIN"
  if ! "$AAPT2_BIN" dump permissions "$APK" > "$WORK/perms.txt" 2>"$WORK/aapt2.err"; then
    fail "aapt2 dump permissions failed on $APK"
    cat "$WORK/aapt2.err" >&2
  else
    log "Merged manifest permissions:"
    sed 's/^/  /' "$WORK/perms.txt"

    # `aapt2 dump permissions` prints "package: <id>" as its first line.
    actual_package="$(awk '/^package: / { print $2; exit }' "$WORK/perms.txt")"
    if [[ "$actual_package" != "$EXPECTED_PACKAGE" ]]; then
      fail "Package id is '${actual_package:-<none>}', expected '$EXPECTED_PACKAGE' — an applicationId change orphans every existing install."
    else
      log "  ok  package id $actual_package"
    fi

    for perm in "${REQUIRED_PERMISSIONS[@]}"; do
      if grep -q "^uses-permission: name='${perm}'" "$WORK/perms.txt"; then
        log "  ok  $perm"
      else
        fail "Merged manifest does not declare $perm — the app will fail at runtime, not at build time."
      fi
    done
  fi
fi

# ── result ──────────────────────────────────────────────────────────────────
if [[ "$FAILURES" -gt 0 ]]; then
  printf '\033[1;31m[verify-apk] %d check(s) FAILED for %s\033[0m\n' "$FAILURES" "$APK" >&2
  exit 1
fi

log "All APK content checks passed for $APK"
