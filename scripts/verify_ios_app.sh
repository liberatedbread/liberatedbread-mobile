#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — verify the CONTENTS of a built iOS bundle.
#
# WHY THIS EXISTS
#
# The iOS CI job was compile-only: `flutter build ios --debug --no-codesign
# --simulator` and nothing else. A compile cannot see the two things that
# actually broke on device:
#
#   1. Info.plist regressions. The BLE usage strings are what make CoreBluetooth
#      raise the system prompt at all — lib/services/real_ble_service.dart
#      deliberately relies on that instead of asking permission_handler. Drop
#      NSBluetoothAlwaysUsageDescription and iOS kills the app the moment it
#      touches CBCentralManager; drop NSLocalNetworkUsageDescription or
#      NSAllowsLocalNetworking and every http:// Home Assistant call fails.
#      All of it compiles perfectly.
#   2. The Rust library not actually being linked in. cargokit builds the crate
#      as a static archive and rust_builder/ios/liberated_bread_core.podspec
#      force-loads it (OTHER_LDFLAGS = -force_load .../libliberated_bread_core.a).
#      If that silently no-ops, the app links, launches, and dies on the first
#      flutter_rust_bridge call. Checking that the .a exists in the build
#      intermediates would NOT catch this — the archive can be present and
#      simply never linked. The only meaningful assertion is whether the FFI
#      entry points survived into a shipped Mach-O.
#
# Accepts either a built .app directory or an .ipa, so the same checks cover the
# CI simulator build and the ad-hoc IPA that goes on a real iPhone.
#
# Usage:
#   ./scripts/verify_ios_app.sh <path-to-Runner.app | path-to.ipa> [--skip-symbols]
#
# Options:
#   --skip-symbols   Only verify Info.plist. Use for release/profile artifacts,
#                    whose binaries are stripped — see the note on the symbol
#                    check below.
#
# Environment:
#   PLISTBUDDY   Path to PlistBuddy (default /usr/libexec/PlistBuddy)
#   NM           Path to nm (default: nm on PATH)
#
# macOS only: PlistBuddy and nm are the tools that can read a built bundle.
# Both are required rather than optional — a runner that lacks them must make
# this script fail, not quietly skip and report success.

set -euo pipefail

EXPECTED_BUNDLE_ID="ca.pigscanfly.liberatedbread"

# Non-empty string keys the app cannot work without. Checked in the BUILT
# bundle, not ios/Runner/Info.plist, so an Xcode build-setting or plist
# preprocessing regression is caught too.
REQUIRED_STRING_KEYS=(
  "NSBluetoothAlwaysUsageDescription"
  "NSBluetoothPeripheralUsageDescription"
  "NSLocalNetworkUsageDescription"
)

# The FFI dispatcher entry points flutter_rust_bridge 2.9 exports from the
# crate and resolves by name at runtime. Apple prefixes C symbols with an
# underscore, hence the optional leading _ in the pattern.
FRB_SYMBOL_PATTERN='_?frb_(pde_ffi_dispatcher_primary|get_rust_content_hash)$'

PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
NM="${NM:-nm}"

TARGET=""
SKIP_SYMBOLS=0

log()  { printf '\033[1;32m[verify-ios]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[verify-ios]\033[0m %s\n' "$*"; }

# Everything a missing-FFI failure needs somebody to know, printed at the
# moment it fails.
#
# WHY THIS EXISTS. The failure this serves says the Rust library "was not
# linked in (podspec -force_load no-op, or cargokit produced nothing)" — two
# very different causes, and the message alone distinguishes neither. This job
# runs on macOS, which bills at 10x, and `flutter build ios` swallows cargokit's
# output entirely, so the evidence is not in the log either. Twice in a row that
# meant a full red run taught nothing and the only way forward was another one.
#
# So: on the way out, say which candidates were Mach-O at all, what
# architectures they carry, how many global symbols they have, and whether ANY
# frb_ symbol is present. Then list what cargokit actually produced. That is
# enough to tell "nothing was built" from "it was built and not linked" from
# "it is linked and the entry points are named something else" — the last being
# a real possibility across flutter_rust_bridge versions, and one this script
# would otherwise misreport as the first.
#
# Only runs on the failure path, so a green run pays nothing for it.
diagnose_missing_ffi() {
  printf '\033[1;33m[verify-ios] --- FFI diagnostics ---\033[0m\n' >&2

  local bin arch syms frb
  for bin in "$@"; do
    # nm exits non-zero on anything that is not an object file, which is the
    # filter used above too: no dependency on `file`.
    if ! "$NM" -g "$bin" >/dev/null 2>&1; then
      continue
    fi
    arch="not available"
    if command -v lipo >/dev/null 2>&1; then
      arch="$(lipo -info "$bin" 2>/dev/null || echo 'lipo failed')"
    fi
    syms="$("$NM" -g "$bin" 2>/dev/null | wc -l | tr -d ' ')"
    # Any frb_ symbol, not just the two expected ones. A non-zero count here
    # with the check still failing means the entry points were RENAMED, which
    # is a completely different fix from "the library is missing".
    frb="$("$NM" -g "$bin" 2>/dev/null | grep -c 'frb_' || true)"
    printf '\033[1;33m[verify-ios]\033[0m   %s\n' "${bin#"$APP/"}" >&2
    printf '\033[1;33m[verify-ios]\033[0m     %s\n' "$arch" >&2
    printf '\033[1;33m[verify-ios]\033[0m     %s global symbols, %s matching frb_\n' \
      "$syms" "$frb" >&2
  done

  # Half the error message's own guess is "cargokit produced nothing" — this
  # answers that directly rather than leaving it a guess. Relative to the repo
  # root, which is where CI invokes this from; absent is itself the answer.
  printf '\033[1;33m[verify-ios]\033[0m   Rust staticlibs under rust/target:\n' >&2
  if [[ -d rust/target ]]; then
    local found=0 lib
    while IFS= read -r lib; do
      found=1
      printf '\033[1;33m[verify-ios]\033[0m     %s (%s bytes)\n' \
        "$lib" "$(wc -c <"$lib" | tr -d ' ')" >&2
      if command -v lipo >/dev/null 2>&1; then
        printf '\033[1;33m[verify-ios]\033[0m       %s\n' \
          "$(lipo -info "$lib" 2>/dev/null || echo 'lipo failed')" >&2
      fi
    done < <(find rust/target -name 'libliberated_bread_core.a' 2>/dev/null)
    [[ "$found" -eq 1 ]] || printf '\033[1;33m[verify-ios]\033[0m     none — cargokit produced no staticlib\n' >&2
  else
    printf '\033[1;33m[verify-ios]\033[0m     rust/target does not exist here\n' >&2
  fi
  printf '\033[1;33m[verify-ios] --- end diagnostics ---\033[0m\n' >&2
}

# Same rationale as scripts/verify_apk.sh: collect every failure so one CI run
# shows the whole picture instead of one problem per push.
FAILURES=0
fail() {
  printf '\033[1;31m[verify-ios] FAIL:\033[0m %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-symbols) SKIP_SYMBOLS=1; shift ;;
    # So the CI summary step can grep for the SAME symbols this script checks,
    # instead of keeping a second copy of the regex that drifts the first time
    # flutter_rust_bridge renames an entry point.
    --print-symbol-pattern) printf '%s\n' "$FRB_SYMBOL_PATTERN"; exit 0 ;;
    -h|--help)
      echo "Usage: $0 <path-to-Runner.app | path-to.ipa> [--skip-symbols]"
      echo "       $0 --print-symbol-pattern"
      exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$TARGET" ]] || { echo "Only one bundle path may be given" >&2; exit 2; }
      TARGET="$1"; shift ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <path-to-Runner.app | path-to.ipa> [--skip-symbols]" >&2
  exit 2
fi

# A workflow typo in the artifact path would otherwise make every check below
# vacuously pass on nothing.
if [[ ! -e "$TARGET" ]]; then
  fail "Bundle not found: $TARGET"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── resolve the .app ────────────────────────────────────────────────────────
APP=""
case "$TARGET" in
  *.ipa)
    command -v unzip >/dev/null 2>&1 || { echo "unzip is required to read an .ipa" >&2; exit 2; }
    log "Unpacking IPA: $TARGET"
    unzip -q "$TARGET" -d "$WORK/ipa" || { fail "Not a readable .ipa: $TARGET"; exit 1; }
    APP="$(find "$WORK/ipa/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
    if [[ -z "$APP" ]]; then
      fail "No Payload/*.app inside $TARGET — this is not an iOS application archive."
      exit 1
    fi
    ;;
  *)
    if [[ ! -d "$TARGET" ]]; then
      fail "Not a .app directory and not an .ipa: $TARGET"
      exit 1
    fi
    APP="$TARGET"
    ;;
esac

log "Verifying bundle: $APP"

PLIST="$APP/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  fail "$APP has no Info.plist — the build did not produce a usable bundle."
  exit 1
fi

if [[ ! -x "$PLISTBUDDY" ]]; then
  fail "PlistBuddy not found at '$PLISTBUDDY' (macOS only). Cannot read the built Info.plist, so no plist check can be trusted."
  exit 1
fi

# ── 1. Info.plist ───────────────────────────────────────────────────────────
# PlistBuddy exits non-zero when a key is absent, so a missing key is a real
# failure rather than an empty string that compares equal to another empty
# string.
plist_get() { "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null; }

for key in "${REQUIRED_STRING_KEYS[@]}"; do
  value="$(plist_get "$key" || true)"
  if [[ -z "$value" ]]; then
    fail "Info.plist key $key is missing or empty — iOS terminates the app when the matching API is used without it."
  else
    log "  ok  $key = $value"
  fi
done

# usesCleartextTraffic has no iOS equivalent; NSAllowsLocalNetworking is what
# lets the app reach a plain-http Home Assistant on the LAN. A bare
# NSAppTransportSecurity dict with the flag flipped to false compiles fine and
# breaks every local connection at runtime, so assert the value, not the key.
ats_local="$(plist_get "NSAppTransportSecurity:NSAllowsLocalNetworking" || true)"
if [[ "$ats_local" != "true" ]]; then
  fail "NSAppTransportSecurity:NSAllowsLocalNetworking is '${ats_local:-<absent>}', expected 'true' — plain-http Home Assistant servers on the LAN would be blocked by ATS."
else
  log "  ok  NSAppTransportSecurity:NSAllowsLocalNetworking = true"
fi

# iOS 14+ withholds mDNS answers for a service type absent from this array, and
# does it silently, so a truncated list is a set of devices that simply never
# appear. The exact contents are cross-checked against the bundled catalogue by
# test/platform/ios_bonjour_catalogue_test.dart; what can only be checked here
# is that the array survived into the BUILT bundle at all.
bonjour_count="$("$PLISTBUDDY" -c "Print :NSBonjourServices" "$PLIST" 2>/dev/null | grep -c '_' || true)"
if [[ "$bonjour_count" -eq 0 ]]; then
  fail "NSBonjourServices is missing or empty in the built Info.plist — iOS delivers no mDNS answers for undeclared service types, so the Wi-Fi scan finds nothing over mDNS and reports it as an empty network."
else
  log "  ok  NSBonjourServices declares $bonjour_count service type(s)"
fi

bundle_id="$(plist_get "CFBundleIdentifier" || true)"
if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
  fail "CFBundleIdentifier is '${bundle_id:-<absent>}', expected '$EXPECTED_BUNDLE_ID' — a mismatch invalidates the provisioning profile and orphans existing installs."
else
  log "  ok  CFBundleIdentifier = $bundle_id"
fi

# ── 2. Entitlements (device builds only) ────────────────────────────────────
# The multicast entitlement is the one thing this app needs that neither
# compiles nor signs into existence by accident: Apple grants it by manual
# request, it lives on the App ID, and it reaches the binary only if the
# provisioning profile used for THIS build carries it. A profile generated
# before the grant produces a perfectly valid, installable IPA whose Wi-Fi scan
# finds nothing at all, and nothing in the build log says so.
#
# Gated on embedded.mobileprovision because only a device build has one. A
# simulator bundle is signed ad-hoc or not at all and has no profile-derived
# entitlements, so asserting there would fail for the wrong reason — the same
# rule the symbol check below follows for stripped binaries.
if [[ -f "$APP/embedded.mobileprovision" ]]; then
  if ! command -v codesign >/dev/null 2>&1; then
    fail "codesign not found. This is a device build (it has an embedded.mobileprovision), so its entitlements cannot be verified and a silently unentitled IPA would pass."
  else
    ENTITLEMENTS="$WORK/entitlements.plist"
    if codesign -d --entitlements :- --xml "$APP" >"$ENTITLEMENTS" 2>/dev/null &&
       [[ -s "$ENTITLEMENTS" ]]; then
      multicast="$("$PLISTBUDDY" -c "Print :com.apple.developer.networking.multicast" "$ENTITLEMENTS" 2>/dev/null || true)"
      if [[ "$multicast" != "true" ]]; then
        fail "com.apple.developer.networking.multicast is '${multicast:-<absent>}' in the signed entitlements, expected 'true'. iOS 14+ blocks raw multicast without it, so every mDNS query and SSDP M-SEARCH this app sends is dropped and the Wi-Fi scan finds nothing. Usually this means the provisioning profile predates the entitlement being granted on the App ID — regenerate it on developer.apple.com and update IOS_PROVISIONING_PROFILE. See docs/ios-from-linux.md."
      else
        log "  ok  com.apple.developer.networking.multicast = true"
      fi
    else
      fail "Could not read the code signature's entitlements from $APP. A device build that cannot be inspected cannot be shown to carry the multicast entitlement, and an IPA without it discovers nothing over Wi-Fi."
    fi
  fi
else
  warn "No embedded.mobileprovision in the bundle — skipping the entitlements check (simulator builds carry no profile-derived entitlements)."
fi

# ── 3. Rust FFI entry points ────────────────────────────────────────────────
if [[ "$SKIP_SYMBOLS" -eq 1 ]]; then
  warn "Skipping the Rust symbol check (--skip-symbols)."
else
  if ! command -v "$NM" >/dev/null 2>&1; then
    fail "nm not found ('$NM'). Cannot verify that the Rust library was linked in."
  else
    executable="$(plist_get "CFBundleExecutable" || true)"
    candidates=()
    if [[ -n "$executable" && -f "$APP/$executable" ]]; then
      candidates+=("$APP/$executable")
    else
      fail "CFBundleExecutable ('${executable:-<absent>}') does not name a file inside the bundle."
    fi
    # Whether the pod links as a static library straight into Runner or as a
    # framework under Frameworks/ depends on the Podfile's use_frameworks!
    # setting, so search both. Either location is a pass; nowhere is a failure.
    if [[ -d "$APP/Frameworks" ]]; then
      while IFS= read -r f; do
        candidates+=("$f")
      done < <(find "$APP/Frameworks" -type f 2>/dev/null)
    fi

    # macOS ships bash 3.2, where expanding an empty array under `set -u` is an
    # "unbound variable" error rather than an empty expansion — so never index
    # into `candidates` without checking the count first.
    found=""
    searched="<none>"
    if [[ ${#candidates[@]} -gt 0 ]]; then
      searched="${candidates[*]}"
      for bin in "${candidates[@]}"; do
        # nm exits non-zero on anything that is not an object file; that is the
        # filter, so no dependency on `file` is needed.
        if "$NM" -g "$bin" 2>/dev/null | grep -qE "$FRB_SYMBOL_PATTERN"; then
          found="$bin"
          break
        fi
      done
    fi

    if [[ -n "$found" ]]; then
      log "  ok  flutter_rust_bridge FFI entry points present in ${found#"$APP/"}"
    else
      # Diagnostics FIRST, so they sit above the failure in the log rather than
      # scrolled off below it.
      if [[ ${#candidates[@]} -gt 0 ]]; then
        diagnose_missing_ffi "${candidates[@]}"
      fi
      fail "No flutter_rust_bridge FFI entry point found in any Mach-O in the bundle. The Rust static library was not linked in (podspec -force_load no-op, or cargokit produced nothing), so the app would crash on its first Rust call. See the diagnostics above for which. Searched: $searched"
    fi
  fi
fi

# ── result ──────────────────────────────────────────────────────────────────
if [[ "$FAILURES" -gt 0 ]]; then
  printf '\033[1;31m[verify-ios] %d check(s) FAILED for %s\033[0m\n' "$FAILURES" "$APP" >&2
  exit 1
fi

log "All iOS bundle checks passed for $APP"
