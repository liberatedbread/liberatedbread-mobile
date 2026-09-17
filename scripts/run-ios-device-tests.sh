#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — run the integration suites on a PHYSICAL iPhone.
#
# The Simulator has no Bluetooth radio, no Local Network privacy and not the
# keychain a shipped app gets, so the CI device jobs prove the state machines
# in mock mode and nothing else. This script runs the suite that only a phone
# can answer — integration_test/device_hardware_test.dart, the shipping
# services against the real radio, Wi-Fi and keychain — and, with --all, the
# same mock-mode aggregate CI runs on the Simulator, so a regression that only
# shows on a device is caught on one.
#
# Usage:
#   ./scripts/run-ios-device-tests.sh                 # hardware suite, first paired iPhone
#   ./scripts/run-ios-device-tests.sh --all           # ...then ci_all_test.dart in mock mode
#   ./scripts/run-ios-device-tests.sh --device HK16   # a specific UDID or name
#   ./scripts/run-ios-device-tests.sh --list          # paired iPhones, then exit
#   ./scripts/run-ios-device-tests.sh --if-present    # exit 0 (not 2) when no iPhone is paired
#   ./scripts/run-ios-device-tests.sh --expect-lan-devices   # a silent Wi-Fi scan is a FAILURE
#   ./scripts/run-ios-device-tests.sh --live-ble-name "SD-1234"  # also connect to that peripheral
#   ./scripts/run-ios-device-tests.sh -- --verbose    # pass extras to `flutter test`
#
# THE MULTICAST ENTITLEMENT
#
# ios/Runner/Runner.entitlements declares com.apple.developer.networking.multicast,
# which Apple grants by manual request. Until the App ID carries it, no
# provisioning profile does either, and a signed device build FAILS at
# codesign ("doesn't include the ... entitlement"). So, by default, this
# script looks for a profile on this Mac that carries the entitlement and,
# finding none, builds with the entitlements file temporarily EMPTIED — the
# original is restored on every exit path, and `git status` is checked
# afterwards. The hardware suite is told (LB_MULTICAST_ENTITLED=false) so it
# treats a silent Wi-Fi scan as expected rather than as a finding.
#
#   --strip-multicast   always build without the entitlement
#   --keep-multicast    never touch the file (the grant has landed and the
#                       profile was regenerated)
#
# What a stripped build cannot test is exactly the thing HARDWARE_LATER.md
# says needs the phone: whether an entitled scan hears the network. Everything
# else in the suite is unaffected.
#
# Exit codes: 0 all green; 1 a test failed or a build failed; 2 no iPhone
# paired (0 with --if-present).

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[ios-device-tests]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ios-device-tests]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ios-device-tests]\033[0m %s\n' "$*" >&2; }

# shellcheck source=ios-device-select.sh
source "$SCRIPT_DIR/ios-device-select.sh"
source "$SCRIPT_DIR/regen-bindings.sh"
source "$SCRIPT_DIR/regen-spec-index.sh"

usage() {
  sed -n '5,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── parse args ───────────────────────────────────────────────────────────────

DEVICE_ID=""
LIST_ONLY=false
RUN_ALL=false
IF_PRESENT=false
EXPECT_LAN=false
LIVE_BLE_NAME=""
MULTICAST_MODE="auto"   # auto | strip | keep
TEST_TIMEOUT="${LB_TEST_TIMEOUT:-900s}"
PASSTHROUGH=()

while (( $# > 0 )); do
  case "$1" in
    --device)
      [[ $# -lt 2 ]] && { err "--device requires a UDID or device name."; exit 2; }
      DEVICE_ID="$2"; shift 2 ;;
    --list)              LIST_ONLY=true; shift ;;
    --all)               RUN_ALL=true; shift ;;
    --if-present)        IF_PRESENT=true; shift ;;
    --expect-lan-devices) EXPECT_LAN=true; shift ;;
    --live-ble-name)
      [[ $# -lt 2 ]] && { err "--live-ble-name requires the advertised name."; exit 2; }
      LIVE_BLE_NAME="$2"; shift 2 ;;
    --strip-multicast)   MULTICAST_MODE="strip"; shift ;;
    --keep-multicast)    MULTICAST_MODE="keep"; shift ;;
    --timeout)
      [[ $# -lt 2 ]] && { err "--timeout requires a value such as 900s."; exit 2; }
      TEST_TIMEOUT="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; PASSTHROUGH+=("$@"); break ;;
    *)                   err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

# ── platform and tools ───────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "Running on an iPhone needs macOS with Xcode. See docs/ios-from-linux.md."
  exit 1
fi
for cmd in flutter xcrun python3 security plutil; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd not found. Install Xcode and its command-line tools."
    exit 1
  fi
done

cd "$PROJECT_DIR"

if [[ "$LIST_ONLY" == "true" ]]; then
  list_ios_devices
  exit 0
fi

# ── the phone ────────────────────────────────────────────────────────────────

UDID=""
if ! UDID="$(pick_ios_device "$DEVICE_ID")"; then
  if [[ "$IF_PRESENT" == "true" ]]; then
    warn "No paired iPhone; nothing to run (--if-present)."
    exit 0
  fi
  exit 2
fi
log "iPhone: $UDID"

# ── the multicast entitlement ────────────────────────────────────────────────

ENTITLEMENTS="ios/Runner/Runner.entitlements"
MULTICAST_KEY="com.apple.developer.networking.multicast"

# Any installed profile that carries the entitlement. Deliberately not
# narrowed to this bundle id: Xcode regenerates the automatic profile as
# capabilities change, and the question is only whether Apple has granted
# the capability to this team at all.
profile_has_multicast() {
  local p
  for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
           "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
    [[ -f "$p" ]] || continue
    if security cms -D -i "$p" 2>/dev/null | grep -q "$MULTICAST_KEY"; then
      return 0
    fi
  done
  return 1
}

ENTITLEMENTS_BACKUP=""
restore_entitlements() {
  if [[ -n "$ENTITLEMENTS_BACKUP" && -f "$ENTITLEMENTS_BACKUP" ]]; then
    cp "$ENTITLEMENTS_BACKUP" "$ENTITLEMENTS"
    rm -f "$ENTITLEMENTS_BACKUP"
    ENTITLEMENTS_BACKUP=""
    log "Restored $ENTITLEMENTS"
  fi
}
trap restore_entitlements EXIT

strip_entitlements() {
  ENTITLEMENTS_BACKUP="$(mktemp)"
  cp "$ENTITLEMENTS" "$ENTITLEMENTS_BACKUP"
  cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
  plutil -lint "$ENTITLEMENTS" >/dev/null
  warn "Building WITHOUT $MULTICAST_KEY (no provisioning profile on this Mac carries it)."
  warn "The Wi-Fi scan will hear nothing; the suite has been told to expect that."
}

MULTICAST_ENTITLED=true
case "$MULTICAST_MODE" in
  keep)  log "Keeping $ENTITLEMENTS as committed (--keep-multicast)." ;;
  strip) strip_entitlements; MULTICAST_ENTITLED=false ;;
  auto)
    if profile_has_multicast; then
      log "A provisioning profile with $MULTICAST_KEY is installed; keeping the entitlement."
    else
      strip_entitlements; MULTICAST_ENTITLED=false
    fi ;;
esac

# ── build inputs ─────────────────────────────────────────────────────────────

regen_frb_bindings
regen_spec_index
if [[ ! -d ".dart_tool" ]]; then
  log "flutter pub get"
  flutter pub get
fi

# ── run ──────────────────────────────────────────────────────────────────────

# What the tree looked like BEFORE the build, so the check at the end reports
# only what the build changed — not edits the developer had in progress.
TREE_BEFORE="$(git status --porcelain -- ios macos .gitignore pubspec.lock)"

DEFINES=(
  --dart-define=LB_HARDWARE=true
  --dart-define=LB_MULTICAST_ENTITLED="$MULTICAST_ENTITLED"
)
[[ "$EXPECT_LAN" == "true" ]] && DEFINES+=(--dart-define=LB_EXPECT_LAN_DEVICES=true)
[[ -n "$LIVE_BLE_NAME" ]] && DEFINES+=(--dart-define=LB_LIVE_BLE_NAME="$LIVE_BLE_NAME")

status=0

log "Hardware suite: integration_test/device_hardware_test.dart"
log "(watch the phone: a fresh install raises the Bluetooth and Local Network alerts, and the suite waits for you to answer them)"
if ! flutter test integration_test/device_hardware_test.dart \
    -d "$UDID" \
    --timeout "$TEST_TIMEOUT" \
    "${DEFINES[@]}" \
    "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"; then
  err "Hardware suite failed."
  status=1
fi

if [[ "$RUN_ALL" == "true" ]]; then
  log "CI aggregate in mock mode: integration_test/ci_all_test.dart"
  if ! flutter test integration_test/ci_all_test.dart \
      -d "$UDID" \
      --timeout "$TEST_TIMEOUT" \
      --dart-define=LIBERATED_BREAD_MOCK=true \
      "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"; then
    err "Mock-mode aggregate failed on the device."
    status=1
  fi
fi

restore_entitlements

# A device build must leave the tree as it found it. The Flutter 3.44.8
# project migration is committed, so any diff here is new and worth a look.
TREE_AFTER="$(git status --porcelain -- ios macos .gitignore pubspec.lock)"
if [[ "$TREE_AFTER" != "$TREE_BEFORE" ]]; then
  warn "The build changed tracked files (before -> after):"
  diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") >&2 || true
fi

if [[ "$status" -eq 0 ]]; then
  log "All device suites passed on $UDID."
fi
exit "$status"
