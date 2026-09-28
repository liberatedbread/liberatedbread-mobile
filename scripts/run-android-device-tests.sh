#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — run the integration suites on a PHYSICAL Android
# phone. The Android twin of scripts/run-ios-device-tests.sh: the emulator has
# no Bluetooth radio and its network is NAT'd through the host, so the CI
# emulator job proves the state machines in mock mode and nothing else.
#
# Usage:
#   ./scripts/run-android-device-tests.sh                # hardware suite, first attached phone
#   ./scripts/run-android-device-tests.sh --all          # ...then ci_all_test.dart in mock mode
#   ./scripts/run-android-device-tests.sh --all --allow-keychain-wipe  # ...including the keychain suite, which WIPES the app's secure storage
#   ./scripts/run-android-device-tests.sh --device <serial-or-name>
#   ./scripts/run-android-device-tests.sh --list         # attached phones, then exit
#   ./scripts/run-android-device-tests.sh --if-present   # exit 0 (not 2) when no phone is attached
#   ./scripts/run-android-device-tests.sh --expect-lan-devices     # a silent Wi-Fi scan is a FAILURE
#   ./scripts/run-android-device-tests.sh --live-ble-name "SD-1234"  # also connect to that peripheral
#   ./scripts/run-android-device-tests.sh --live-ble-any           # connect to the nearest connectable one
#   ./scripts/run-android-device-tests.sh --live-ble-sequence "GVH5075,Airthings"  # connect to each, in order, twice over (name prefixes)
#   ./scripts/run-android-device-tests.sh -- --verbose   # pass extras to `flutter test`
#
# No entitlement dance here: Android needs no multicast entitlement, the app
# takes the WifiManager multicast lock itself. The permissions the suite
# needs (Bluetooth / nearby devices, and location on older Android) are
# requested by the app on first launch — answer the prompts on the phone.
#
# The test APK has the app's own applicationId and debug key, so it REPLACES
# a `run-android.sh` install on the phone and runs against that install's
# saved devices, credentials, pins and accepted Terms. It is never uninstalled
# afterwards (--no-uninstall), which would have deleted all of that. Instead,
# once the suites are done, pass or fail, the real app (lib/main.dart, debug)
# is built and `adb install -r`'d over it, data kept: left in place, the test
# build IS the home-screen icon, and each tap reruns the suite, including
# (after --allow-keychain-wipe) the secure-storage wipe. If that reinstall
# fails the run exits 1 and says to rerun ./scripts/run-android.sh.
#
# Exit codes: 0 all green; 1 a test failed or a build failed; 2 no phone
# attached (0 with --if-present).

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[android-device-tests]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[android-device-tests]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[android-device-tests]\033[0m %s\n' "$*" >&2; }

# shellcheck source=android-device-select.sh
source "$SCRIPT_DIR/android-device-select.sh"
source "$SCRIPT_DIR/regen-bindings.sh"
source "$SCRIPT_DIR/regen-spec-index.sh"
# Defines ensure_gradle_jdk, called before the build below, as run-android.sh does.
# shellcheck source=ensure-gradle-jdk.sh
source "$SCRIPT_DIR/ensure-gradle-jdk.sh"

usage() { sed -n '5,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DEVICE_ID=""
LIST_ONLY=false
RUN_ALL=false
ALLOW_KEYCHAIN_WIPE=false
IF_PRESENT=false
EXPECT_LAN=false
LIVE_BLE_NAME=""
LIVE_BLE_ANY=false
LIVE_BLE_SEQUENCE=""
TEST_TIMEOUT="${LB_TEST_TIMEOUT:-900s}"
PASSTHROUGH=()

while (( $# > 0 )); do
  case "$1" in
    --device)
      [[ $# -lt 2 ]] && { err "--device requires a serial or device name."; exit 2; }
      DEVICE_ID="$2"; shift 2 ;;
    --list)               LIST_ONLY=true; shift ;;
    --all)                RUN_ALL=true; shift ;;
    --allow-keychain-wipe) ALLOW_KEYCHAIN_WIPE=true; shift ;;
    --if-present)         IF_PRESENT=true; shift ;;
    --expect-lan-devices) EXPECT_LAN=true; shift ;;
    --live-ble-name)
      [[ $# -lt 2 ]] && { err "--live-ble-name requires the advertised name."; exit 2; }
      LIVE_BLE_NAME="$2"; shift 2 ;;
    --live-ble-any)       LIVE_BLE_ANY=true; shift ;;
    --live-ble-sequence)
      [[ $# -lt 2 ]] && { err "--live-ble-sequence requires a comma-separated list of advertised-name prefixes."; exit 2; }
      LIVE_BLE_SEQUENCE="$2"; shift 2 ;;
    --timeout)
      [[ $# -lt 2 ]] && { err "--timeout requires a value such as 900s."; exit 2; }
      TEST_TIMEOUT="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    --)                   shift; PASSTHROUGH+=("$@"); break ;;
    *)                    err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

# As in the iOS runner: the opt-in only reaches keychain_accessibility_test.dart
# through the --all aggregate, and passed alone it would say nothing.
if [[ "$ALLOW_KEYCHAIN_WIPE" == "true" && "$RUN_ALL" != "true" ]]; then
  err "--allow-keychain-wipe does nothing without --all: keychain_accessibility_test.dart runs only in the mock-mode aggregate."
  exit 2
fi

for cmd in flutter python3; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd not found. Run ./scripts/setup.sh."
    exit 1
  fi
done

cd "$PROJECT_DIR"

if [[ "$LIST_ONLY" == "true" ]]; then
  list_android_devices
  exit 0
fi

DEVICE=""
# Read through `|| pick_rc=$?`, not `if ! DEVICE="$(…)"` — see the iOS runner:
# the `!` inverts the status and `$?` in that branch is always 0.
pick_rc=0
DEVICE="$(pick_android_device "$DEVICE_ID")" || pick_rc=$?
if (( pick_rc != 0 )); then
  # Exit 2 only — see the iOS runner. Exit 1 is "flutter devices --machine
  # could not be parsed", a broken toolchain rather than an absent phone, and
  # --if-present must not report success for it.
  # 2 only, never 3: exit 3 is "a phone is here, but not the one --device
  # named", which is a mistake to report, not hardware to skip. Swallowing it
  # said "no phone; nothing to run" with a phone plugged in and exited 0.
  if [[ "$IF_PRESENT" == "true" && "$pick_rc" -eq 2 ]]; then
    warn "No attached Android phone; nothing to run (--if-present)."
    exit 0
  fi
  exit "$pick_rc"
fi
log "Android phone: $DEVICE"
warn "The test build REPLACES any installed ca.pigscanfly.liberatedbread debug build on this phone and runs against its saved data."

regen_frb_bindings
regen_spec_index
ensure_gradle_jdk
if [[ ! -d ".dart_tool" ]]; then
  log "flutter pub get"
  flutter pub get
fi

DEFINES=(
  --dart-define=LB_HARDWARE=true
  --dart-define=LB_MULTICAST_ENTITLED=true
)
[[ "$EXPECT_LAN" == "true" ]] && DEFINES+=(--dart-define=LB_EXPECT_LAN_DEVICES=true)
[[ -n "$LIVE_BLE_NAME" ]] && DEFINES+=(--dart-define=LB_LIVE_BLE_NAME="$LIVE_BLE_NAME")
[[ "$LIVE_BLE_ANY" == "true" ]] && DEFINES+=(--dart-define=LB_LIVE_BLE_ANY=true)
[[ -n "$LIVE_BLE_SEQUENCE" ]] && DEFINES+=(--dart-define=LB_LIVE_BLE_SEQUENCE="$LIVE_BLE_SEQUENCE")

status=0

# True from the first `flutter test` until the real app is back on the phone.
# Read by the EXIT trap, so a Ctrl-C or a `set -e` exit mid-run still says
# what the phone's icon now launches.
TEST_BUILD_ON_PHONE=false
# shellcheck disable=SC2317,SC2329  # reached through the trap below, which shellcheck cannot see (SC2317 is 0.9's code for it, the runner's version)
warn_test_build_left() {
  [[ "$TEST_BUILD_ON_PHONE" == "true" ]] || return 0
  err "The phone is left on the TEST build: its app icon runs the integration suite, not the app, against the app's real data."
  if [[ "$ALLOW_KEYCHAIN_WIPE" == "true" ]]; then
    err "That build has LB_KEYCHAIN_WIPE_OK compiled in: every launch from the icon WIPES the app's secure storage again."
  fi
  err "Put the app back before opening it: ./scripts/run-android.sh --device $DEVICE --sideload --no-launch"
}
trap warn_test_build_left EXIT

# The build `flutter test -d` leaves behind has the suite as its Dart
# entrypoint and its dart-defines compiled in. Rebuild lib/main.dart as
# run-android.sh --sideload does and install it OVER the test build: -r keeps
# the data --no-uninstall kept (a bare `flutter install` would uninstall
# first, and would install the last-built APK, the test one).
restore_real_app() {
  local adb apk=build/app/outputs/flutter-apk/app-debug.apk
  log "Putting the app back: flutter build apk --debug -t lib/main.dart, then adb install -r (data kept)"
  if ! adb="$(find_adb)"; then
    err "adb not found, so the app could not be reinstalled."
    return 1
  fi
  if ! flutter build apk --debug -t lib/main.dart; then
    err "Rebuilding the app failed."
    return 1
  fi
  # -d as in run-android.sh: allow a version-code downgrade during dev.
  if ! "$adb" -s "$DEVICE" install -r -d "$apk"; then
    err "Reinstalling the app failed."
    return 1
  fi
  TEST_BUILD_ON_PHONE=false
  log "The app is back on the phone, its data kept."
}

log "Hardware suite: integration_test/device_hardware_test.dart"
log "(watch the phone: the first launch asks for Bluetooth / nearby-devices permission, and the suite waits for the answer)"
# --no-uninstall: `flutter test -d` uninstalls the app when the run ends by
# default, and the app it removes is the operator's own install (same id,
# same key): saved devices, secure-storage credentials, pins and Terms gone.
TEST_BUILD_ON_PHONE=true
if ! flutter test integration_test/device_hardware_test.dart \
    -d "$DEVICE" \
    --no-uninstall \
    --timeout "$TEST_TIMEOUT" \
    "${DEFINES[@]}" \
    "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"; then
  err "Hardware suite failed."
  status=1
fi

if [[ "$RUN_ALL" == "true" ]]; then
  log "CI aggregate in mock mode: integration_test/ci_all_test.dart"
  # keychain_accessibility_test.dart's fresh-install case runs the store's
  # sweep, deleteAll with no constraint, against this install's secure
  # storage. LB_PHYSICAL_PHONE tells the suite it is on a phone (the emulator
  # lanes never define it), and it refuses unless LB_KEYCHAIN_WIPE_OK is set,
  # which only --allow-keychain-wipe does here.
  wipe_define=()
  if [[ "$ALLOW_KEYCHAIN_WIPE" == "true" ]]; then
    warn "--allow-keychain-wipe: keychain_accessibility_test.dart WILL DELETE every secure-storage item of ca.pigscanfly.liberatedbread on this phone."
    wipe_define=(--dart-define=LB_KEYCHAIN_WIPE_OK=true)
  else
    log "keychain_accessibility_test.dart will skip on the phone (its fresh-install case wipes the app's secure storage); pass --allow-keychain-wipe on a phone whose credentials are disposable."
  fi
  if ! flutter test integration_test/ci_all_test.dart \
      -d "$DEVICE" \
      --no-uninstall \
      --timeout "$TEST_TIMEOUT" \
      --dart-define=LIBERATED_BREAD_MOCK=true \
      --dart-define=LB_PHYSICAL_PHONE=true \
      "${wipe_define[@]+"${wipe_define[@]}"}" \
      "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"; then
    err "Mock-mode aggregate failed on the phone."
    status=1
  fi
fi

if ! restore_real_app; then
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  log "All device suites passed on $DEVICE."
fi
exit "$status"
