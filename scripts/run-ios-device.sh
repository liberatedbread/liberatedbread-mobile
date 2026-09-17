#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — build and run on a connected physical iPhone
#
# Requires macOS with Xcode and a paired iPhone (USB or wireless).
# Supports hot reload via `flutter run --hot` (the default).
#
# Usage:
#   ./scripts/run-ios-device.sh                     # First paired iPhone found
#   ./scripts/run-ios-device.sh --mock              # Simulated BLE devices
#   ./scripts/run-ios-device.sh --release           # Release build (no hot reload)
#   ./scripts/run-ios-device.sh --device <id>       # Specific device UDID or name
#   ./scripts/run-ios-device.sh --list              # List paired iPhones and exit
#   ./scripts/run-ios-device.sh --mock -- --verbose # Pass extras to `flutter run`
#
# WIRELESS PAIRING (one-time setup on macOS):
#   1. Connect iPhone via USB.
#   2. Open Xcode → Window → Devices and Simulators.
#   3. Check "Connect via network" next to your device.
#   4. Unplug USB — the device stays paired over Wi-Fi.
#   After pairing, this script discovers the device automatically.

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[ios-device]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ios-device]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ios-device]\033[0m %s\n' "$*" >&2; }

source "$SCRIPT_DIR/regen-bindings.sh"
source "$SCRIPT_DIR/regen-spec-index.sh"

# ── platform check ───────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "iOS device builds require macOS with Xcode."
  err ""
  err "From this Linux environment, use one of these options:"
  err "  1. Remote Mac over SSH with auto hot reload: ./scripts/run-remote-mac.sh --host user@mac"
  err "  2. Push, then pull on your Mac and run: ./scripts/run-ios-device.sh"
  err "  3. Trigger a CI build: gh workflow run ios-adhoc.yml"
  err "  4. See docs/ios-from-linux.md for the full workflows."
  exit 1
fi

# ── parse args ───────────────────────────────────────────────────────────────

MOCK=false
RELEASE=false
DEVICE_ID=""
LIST_ONLY=false
PASSTHROUGH=()
SEEN_DDASH=false

while (( $# > 0 )); do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$1"); shift; continue
  fi
  case "$1" in
    --mock)    MOCK=true; shift ;;
    --release) RELEASE=true; shift ;;
    --list)    LIST_ONLY=true; shift ;;
    --device)
      [[ $# -lt 2 ]] && { err "--device requires a UDID or device name."; exit 1; }
      DEVICE_ID="$2"; shift 2 ;;
    --)        SEEN_DDASH=true; shift ;;
    *)         PASSTHROUGH+=("$1"); shift ;;
  esac
done

# ── tool checks ──────────────────────────────────────────────────────────────

for cmd in flutter xcode-select xcrun; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd not found. Install Xcode and the Xcode command-line tools."
    exit 1
  fi
done

if ! xcode-select -p &>/dev/null; then
  err "Xcode not installed. Install it from the App Store."
  exit 1
fi

# ── list or select device ────────────────────────────────────────────────────

# The picker is shared with scripts/run-ios-device-tests.sh, so both agree
# on what "a paired iPhone" is and where the JSON goes.
# shellcheck source=ios-device-select.sh
source "$SCRIPT_DIR/ios-device-select.sh"

if [[ "$LIST_ONLY" == "true" ]]; then
  list_ios_devices
  exit 0
fi

# ── project dependencies ─────────────────────────────────────────────────────

cd "$PROJECT_DIR"
# A rebuild that reflects the current Rust: regenerate the FFI bindings if the
# Rust API changed since they were last generated (no-op otherwise).
regen_frb_bindings
regen_spec_index
if [[ ! -d ".dart_tool" ]]; then
  log "Running flutter pub get..."
  flutter pub get
fi

if [[ -f "$PROJECT_DIR/ios/Podfile" ]]; then
  if ! command -v pod &>/dev/null; then
    err "CocoaPods not installed. Run: sudo gem install cocoapods"
    exit 1
  fi
  if [[ ! -f "$PROJECT_DIR/ios/Podfile.lock" ]] \
    || [[ "$PROJECT_DIR/ios/Podfile" -nt "$PROJECT_DIR/ios/Podfile.lock" ]]; then
    log "Running pod install..."
    (cd "$PROJECT_DIR/ios" && pod install)
  fi
fi

# ── select device ────────────────────────────────────────────────────────────

UDID="$(pick_ios_device "$DEVICE_ID")"
if [[ -z "$UDID" ]]; then
  err "Could not select an iPhone."
  exit 1
fi

# Print the human name alongside the UDID for clarity.
DEVICE_NAME_DISPLAY="$(flutter devices --machine 2>/dev/null \
  | python3 -c "
import json, sys
udid = '$UDID'
try:
    ds = json.load(sys.stdin)
    for d in ds:
        if d.get('id') == udid:
            print(d.get('name', udid))
            sys.exit(0)
except Exception:
    pass
print(udid)
" 2>/dev/null || echo "$UDID")"

log "Target device: $DEVICE_NAME_DISPLAY ($UDID)"

# ── build flutter args ───────────────────────────────────────────────────────

FLUTTER_ARGS=("run" "-d" "$UDID")

if [[ "$RELEASE" == "true" ]]; then
  FLUTTER_ARGS+=("--release")
  log "Release build — hot reload disabled."
else
  # Debug mode enables Dart VM service for hot reload/restart.
  FLUTTER_ARGS+=("--hot")
  log "Debug build — hot reload enabled (r = reload, R = restart, q = quit)."
fi

if [[ "$MOCK" == "true" ]]; then
  log "Mock mode — simulated BLE devices."
  FLUTTER_ARGS+=("--dart-define=LIBERATED_BREAD_MOCK=true")
fi

if (( ${#PASSTHROUGH[@]} > 0 )); then
  FLUTTER_ARGS+=("${PASSTHROUGH[@]}")
fi

log "Running: flutter ${FLUTTER_ARGS[*]}"
exec flutter "${FLUTTER_ARGS[@]}"
