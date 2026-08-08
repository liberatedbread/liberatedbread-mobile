#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — verify the CONTENTS of a built Linux desktop bundle.
#
# WHY THIS EXISTS
#
# `flutter build linux` exiting 0 says nothing about what landed in the bundle,
# and the Linux target has one specific, already-real trap:
#
#   1. The cargokit plugin-name bug. Flutter's generated
#      linux/flutter/generated_plugins.cmake bundles an FFI plugin's native
#      output by dereferencing ${<plugin_name>_bundled_libraries}, where
#      <plugin_name> comes from rust_builder/pubspec.yaml — `liberated_bread_core`.
#      rust_builder/linux/CMakeLists.txt shipped for months exporting
#      `rust_lib_liberated_bread_mobile_bundled_libraries` instead (the name
#      cargokit's template generates). CMake does not error on an undefined
#      variable — it expands to the empty string — so the install() loop simply
#      copies nothing, the build goes green, and the app dies on the first FFI
#      call with "Invalid argument(s): Failed to lookup symbol". This was
#      dormant only because no linux/ target existed. This script is what keeps
#      it from coming back, for the Linux and (by the same mechanism) Windows
#      scaffolds.
#   2. A missing RUNPATH. The bundled .so is found at runtime only because the
#      executable carries RUNPATH=$ORIGIN/lib (set by CMAKE_INSTALL_RPATH in
#      linux/CMakeLists.txt). Drop that line and the .so is still in the bundle,
#      the build is still green, and the app still cannot load it.
#
# So a present-and-correct .so is necessary but not sufficient: this checks the
# library is there, is real (not a stub), still exports the flutter_rust_bridge
# entry points, and is actually reachable from the binary.
#
# Run it locally exactly the way CI does (the scripts/verify_apk.sh pattern):
#
#   ./scripts/verify_linux_bundle.sh build/linux/x64/release/bundle
#
# Usage:
#   ./scripts/verify_linux_bundle.sh <path-to-bundle-dir> [options]
#
# Options:
#   --mode auto|debug|release  Which Flutter build mode produced the bundle.
#                              Default auto, inferred from the path. Debug and
#                              release ship genuinely different payloads (an
#                              AOT lib/libapp.so vs a JIT kernel_blob.bin), so
#                              the mode-specific assertion follows the mode.
#   --min-so-bytes N           Size floor for libliberated_bread_core.so
#                              (default: 65536).
#   --skip-symbols             Skip the exported-symbol check. Not needed for
#                              this project's release builds — a cdylib keeps
#                              its .dynsym through rust/Cargo.toml's
#                              strip = "symbols" — but left as an escape hatch
#                              so an unreadable artifact can still be checked
#                              for presence.
#
# Environment:
#   NM        nm binary to use (default: nm).
#   READELF   readelf binary to use (default: readelf).

set -euo pipefail

# The cdylib cargokit builds from rust/Cargo.toml. The name is load-bearing:
# [lib] name = "liberated_bread_core", and Dart resolves the library by exactly
# this file name at runtime.
RUST_LIB="libliberated_bread_core.so"

# Flutter's own engine. Its presence is what distinguishes "the bundle is
# broken" from "the Rust library specifically is missing" — the same
# discrimination scripts/verify_apk.sh makes per ABI.
FLUTTER_ENGINE_LIB="libflutter_linux_gtk.so"

# The executable name comes from BINARY_NAME in linux/CMakeLists.txt.
BINARY_NAME="liberated_bread_mobile"

# The FFI dispatcher entry points flutter_rust_bridge 2.9 exports from the crate
# and resolves by name at runtime. Same contract scripts/verify_ios_app.sh
# asserts on the iOS binary; no Apple underscore prefix in ELF.
FRB_SYMBOL_PATTERN='frb_(pde_ffi_dispatcher_primary|get_rust_content_hash)$'

# Native plugin libraries for the federated Linux implementations that the app
# genuinely depends on. These are the FLUTTER_PLUGIN_LIST half of
# generated_plugins.cmake, so they catch a plugin-registration regression that
# the FFI check above would not:
#   flutter_secure_storage_linux  Home Assistant token storage (libsecret)
#   url_launcher_linux            opening the HA/docs links in the UI
# NOTE: flutter_blue_plus_linux is deliberately NOT here. Its Linux
# implementation is pure Dart over BlueZ's D-Bus API, so it ships no .so and
# never appears in the bundle — asserting on it would fail every build.
REQUIRED_PLUGIN_LIBS=(
  "libflutter_secure_storage_linux_plugin.so"
  "liburl_launcher_linux_plugin.so"
)

# Size floor for the Rust library. A real debug build is ~26 MB (unstripped,
# with debug_info) and a real release build is far smaller — rust/Cargo.toml's
# release profile sets opt-level = "z", thin LTO and strip = "symbols" — but
# both are orders of magnitude above 64 KiB. This floor sits well under any
# genuine build and well over the 0-byte or few-KB file a broken link or strip
# step leaves behind, which is the failure mode it exists to catch.
MIN_SO_BYTES=65536

MODE="auto"
SKIP_SYMBOLS=0
BUNDLE=""

NM="${NM:-nm}"
READELF="${READELF:-readelf}"

log()  { printf '\033[1;32m[verify-linux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[verify-linux]\033[0m %s\n' "$*"; }

# Failures accumulate instead of aborting on the first one: when a bundle is
# broken it is far more useful to see "the .so is missing AND the RUNPATH is
# gone" in a single CI run than to fix them one per push.
FAILURES=0
fail() {
  printf '\033[1;31m[verify-linux] FAIL:\033[0m %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

usage() {
  cat <<'EOF'
Usage: verify_linux_bundle.sh <path-to-bundle-dir> [options]

Options:
  --mode auto|debug|release  Build mode that produced the bundle (default: auto,
                             inferred from the path).
  --min-so-bytes N           Size floor for libliberated_bread_core.so
                             (default: 65536).
  --skip-symbols             Skip the exported-symbol check.

Environment:
  NM                         nm binary to use (default: nm).
  READELF                    readelf binary to use (default: readelf).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { echo "--mode needs a value" >&2; exit 2; }
      MODE="$2"; shift 2 ;;
    --min-so-bytes)
      [[ $# -ge 2 ]] || { echo "--min-so-bytes needs a value" >&2; exit 2; }
      MIN_SO_BYTES="$2"; shift 2 ;;
    --skip-symbols)
      SKIP_SYMBOLS=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$BUNDLE" ]] || { echo "Only one bundle path may be given" >&2; exit 2; }
      BUNDLE="$1"; shift ;;
  esac
done

if [[ -z "$BUNDLE" ]]; then
  echo "Usage: $0 <path-to-bundle-dir> [--mode auto|debug|release] [--min-so-bytes N] [--skip-symbols]" >&2
  exit 2
fi

case "$MODE" in
  auto|debug|release) ;;
  *) echo "--mode must be one of: auto, debug, release (got '$MODE')" >&2; exit 2 ;;
esac

# Guard the path itself. A workflow typo would otherwise make every check below
# vacuously "pass nothing", which is how a verifier quietly stops verifying.
if [[ ! -d "$BUNDLE" ]]; then
  fail "Bundle directory not found: $BUNDLE"
  exit 1
fi

BUNDLE="${BUNDLE%/}"
LIB_DIR="$BUNDLE/lib"
DATA_DIR="$BUNDLE/data"

# Infer the build mode from the path Flutter writes
# (build/linux/<arch>/<mode>/bundle) when the caller did not pin it.
if [[ "$MODE" == "auto" ]]; then
  case "$BUNDLE" in
    */release/bundle) MODE="release" ;;
    */debug/bundle)   MODE="debug" ;;
    */profile/bundle) MODE="release" ;;  # profile is AOT too
    *)
      fail "Cannot infer the build mode from '$BUNDLE' — pass --mode debug|release explicitly."
      exit 1 ;;
  esac
fi

log "Verifying $BUNDLE (mode: $MODE)"

# ── 1. the executable ───────────────────────────────────────────────────────
EXE="$BUNDLE/$BINARY_NAME"
if [[ ! -f "$EXE" ]]; then
  fail "Executable '$BINARY_NAME' is missing from the bundle root — BINARY_NAME in linux/CMakeLists.txt changed, or the link step produced nothing."
elif [[ ! -x "$EXE" ]]; then
  fail "$EXE exists but is not executable."
else
  log "  ok  $BINARY_NAME ($(stat -c%s "$EXE") bytes)"
fi

# ── 2. the Rust library — the whole point of this script ────────────────────
if [[ ! -d "$LIB_DIR" ]]; then
  fail "No lib/ directory in the bundle at all — the native build produced nothing."
else
  log "Bundled libraries:"
  # Sorted so the log reads as a stable table run over run.
  find "$LIB_DIR" -maxdepth 1 -name '*.so' -printf '  %10s  %f\n' 2>/dev/null | sort -k2 || true

  rust_so="$LIB_DIR/$RUST_LIB"
  if [[ ! -f "$rust_so" ]]; then
    if [[ -f "$LIB_DIR/$FLUTTER_ENGINE_LIB" ]]; then
      # The exact signature of the cargokit plugin-name regression this script
      # exists for: Flutter's own engine made it into the bundle, ours did not.
      fail "lib/$RUST_LIB is MISSING while lib/$FLUTTER_ENGINE_LIB is present — cargokit did not bundle the Rust library. Check that PROJECT_NAME and the *_bundled_libraries variable in rust_builder/linux/CMakeLists.txt both match the plugin name in rust_builder/pubspec.yaml (liberated_bread_core)."
    else
      fail "lib/$RUST_LIB is MISSING (and so is lib/$FLUTTER_ENGINE_LIB) — the bundle is not a completed Flutter Linux build."
    fi
  else
    so_size="$(stat -c%s "$rust_so")"
    if [[ "$so_size" -lt "$MIN_SO_BYTES" ]]; then
      fail "lib/$RUST_LIB is only ${so_size} bytes (floor ${MIN_SO_BYTES}) — a stub or truncated link output, not a real build."
    else
      log "  ok  lib/$RUST_LIB (${so_size} bytes)"
    fi

    # It must also be a real x86-64 ELF shared object, not a leftover text file
    # or a wrong-architecture artifact from a cross build.
    if ! head -c4 "$rust_so" | grep -q $'\x7fELF'; then
      fail "lib/$RUST_LIB is not an ELF object."
    fi

    # ── 3. exported FFI entry points ────────────────────────────────────────
    # Presence is not enough: a library that no longer exports the dispatcher
    # symbols fails at the first FFI call, exactly like a missing one.
    if [[ "$SKIP_SYMBOLS" -eq 1 ]]; then
      warn "Skipping the Rust symbol check (--skip-symbols)."
    elif ! command -v "$NM" >/dev/null 2>&1; then
      fail "$NM not found — cannot verify exported symbols. Install binutils or pass --skip-symbols."
    else
      # -D reads .dynsym, which a cdylib keeps even under strip = "symbols".
      if syms="$("$NM" -D --defined-only "$rust_so" 2>/dev/null)"; then
        if printf '%s\n' "$syms" | grep -qE "$FRB_SYMBOL_PATTERN"; then
          log "  ok  exports the flutter_rust_bridge dispatcher symbols"
        else
          fail "lib/$RUST_LIB exports no symbol matching /$FRB_SYMBOL_PATTERN/ — the FFI entry points are gone, so every Rust call would fail at runtime."
        fi
      else
        fail "$NM could not read lib/$RUST_LIB."
      fi
    fi
  fi

  # ── 4. Flutter engine + federated plugin libraries ────────────────────────
  if [[ ! -f "$LIB_DIR/$FLUTTER_ENGINE_LIB" ]]; then
    fail "lib/$FLUTTER_ENGINE_LIB is missing — the Flutter engine was not bundled."
  else
    log "  ok  lib/$FLUTTER_ENGINE_LIB"
  fi

  for plugin_lib in "${REQUIRED_PLUGIN_LIBS[@]}"; do
    if [[ -f "$LIB_DIR/$plugin_lib" ]]; then
      log "  ok  lib/$plugin_lib"
    else
      fail "lib/$plugin_lib is missing — its plugin dropped out of linux/flutter/generated_plugins.cmake, so its platform channels are unavailable at runtime."
    fi
  done
fi

# ── 5. RUNPATH: the bundled .so must be reachable ───────────────────────────
# A correct bundle with no RUNPATH is still a broken app, and nothing else in
# the build would complain.
if [[ -f "$EXE" ]]; then
  if ! command -v "$READELF" >/dev/null 2>&1; then
    warn "$READELF not found — skipping the RUNPATH check."
  else
    runpath="$("$READELF" -d "$EXE" 2>/dev/null | grep -E 'RUNPATH|RPATH' || true)"
    # shellcheck disable=SC2016  # $ORIGIN below is a literal dynamic-linker token, not a shell variable
    if [[ -z "$runpath" ]]; then
      fail "$BINARY_NAME declares no RUNPATH/RPATH — it cannot find lib/$RUST_LIB at runtime. CMAKE_INSTALL_RPATH in linux/CMakeLists.txt should be \$ORIGIN/lib."
    elif printf '%s' "$runpath" | grep -q '\$ORIGIN/lib'; then
      log "  ok  RUNPATH includes \$ORIGIN/lib"
    else
      fail "$BINARY_NAME RUNPATH does not include \$ORIGIN/lib (got: $(printf '%s' "$runpath" | tr -s ' ')) — the bundled libraries would not be found at runtime."
    fi
  fi
fi

# ── 6. Dart payload for the build mode ──────────────────────────────────────
# Debug is JIT (kernel_blob.bin inside flutter_assets); release/profile is AOT
# (lib/libapp.so). Asserting the right one per mode catches a bundle that was
# assembled for the wrong mode, which otherwise looks complete.
if [[ ! -d "$DATA_DIR/flutter_assets" ]]; then
  fail "data/flutter_assets/ is missing — the Dart assets were never installed."
else
  log "  ok  data/flutter_assets/"
fi

if [[ ! -f "$DATA_DIR/icudtl.dat" ]]; then
  fail "data/icudtl.dat is missing — the engine cannot initialise without it."
else
  log "  ok  data/icudtl.dat"
fi

if [[ "$MODE" == "release" ]]; then
  if [[ ! -f "$LIB_DIR/libapp.so" ]]; then
    fail "lib/libapp.so is missing from a release bundle — the Dart AOT snapshot was not installed."
  else
    log "  ok  lib/libapp.so ($(stat -c%s "$LIB_DIR/libapp.so") bytes AOT snapshot)"
  fi
else
  if [[ ! -f "$DATA_DIR/flutter_assets/kernel_blob.bin" ]]; then
    fail "data/flutter_assets/kernel_blob.bin is missing from a debug bundle — the JIT kernel snapshot was not installed."
  else
    log "  ok  data/flutter_assets/kernel_blob.bin"
  fi
fi

# ── result ──────────────────────────────────────────────────────────────────
if [[ "$FAILURES" -gt 0 ]]; then
  printf '\033[1;31m[verify-linux] %d check(s) FAILED for %s\033[0m\n' "$FAILURES" "$BUNDLE" >&2
  exit 1
fi

log "All Linux bundle checks passed for $BUNDLE"
