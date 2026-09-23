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
#   ./scripts/run-ios-device-tests.sh --all --allow-keychain-wipe  # ...including the keychain suite, which WIPES this phone's app keychain
#   ./scripts/run-ios-device-tests.sh --device HK16   # a specific UDID or name
#   ./scripts/run-ios-device-tests.sh --list          # paired iPhones, then exit
#   ./scripts/run-ios-device-tests.sh --if-present    # exit 0 (not 2) when no iPhone is paired
#   ./scripts/run-ios-device-tests.sh --expect-lan-devices   # a silent Wi-Fi scan is a FAILURE
#   ./scripts/run-ios-device-tests.sh --live-ble-name "SD-1234"  # also connect to that peripheral
#   ./scripts/run-ios-device-tests.sh --live-ble-any             # ...or to the nearest connectable one
#   ./scripts/run-ios-device-tests.sh --launcher flutter   # `flutter test -d`, see below
#   ./scripts/run-ios-device-tests.sh --launcher flutter -- --verbose  # extras for `flutter test`
#
# HOW THE SUITE REACHES THE PHONE
#
# By default (--launcher xcodebuild) each suite is built as the Runner app's
# Dart target and run through `xcodebuild test` on the RunnerTests XCTest
# target (ios/RunnerTests/RunnerTests.m hosts it): the Dart tests come back
# as individual XCTest cases, an .xcresult bundle lands under
# build/ios-device-tests/, and nothing needs Xcode.app. That matters because
# `flutter test -d <udid>` (--launcher flutter) attaches a debugger through
# Xcode.app on iOS 17+, which needs macOS to let this shell control Xcode —
# an Automation prompt that a script cannot answer, and a hang when it is
# never answered. The flutter lane still streams output live and is the one
# to use from a shell that has that permission.
#
# Either way, watch the phone: a fresh install raises the Bluetooth and Local
# Network alerts and the suite waits for you to answer them.
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
# What a stripped build cannot test is exactly the thing the hardware
# checklist says needs the phone: whether an entitled scan hears the
# network. Everything
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
  sed -n '5,65p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ── parse args ───────────────────────────────────────────────────────────────

DEVICE_ID=""
LIST_ONLY=false
RUN_ALL=false
ALLOW_KEYCHAIN_WIPE=false
IF_PRESENT=false
EXPECT_LAN=false
LIVE_BLE_NAME=""
LIVE_BLE_ANY=false
MULTICAST_MODE="auto"   # auto | strip | keep
LAUNCHER="${LB_IOS_LAUNCHER:-xcodebuild}"   # xcodebuild | flutter
TEST_TIMEOUT="${LB_TEST_TIMEOUT:-900s}"
PASSTHROUGH=()

while (( $# > 0 )); do
  case "$1" in
    --device)
      [[ $# -lt 2 ]] && { err "--device requires a UDID or device name."; exit 2; }
      DEVICE_ID="$2"; shift 2 ;;
    --list)              LIST_ONLY=true; shift ;;
    --all)               RUN_ALL=true; shift ;;
    --allow-keychain-wipe) ALLOW_KEYCHAIN_WIPE=true; shift ;;
    --if-present)        IF_PRESENT=true; shift ;;
    --expect-lan-devices) EXPECT_LAN=true; shift ;;
    --live-ble-name)
      [[ $# -lt 2 ]] && { err "--live-ble-name requires the advertised name."; exit 2; }
      LIVE_BLE_NAME="$2"; shift 2 ;;
    --live-ble-any)      LIVE_BLE_ANY=true; shift ;;
    --strip-multicast)   MULTICAST_MODE="strip"; shift ;;
    --keep-multicast)    MULTICAST_MODE="keep"; shift ;;
    --timeout)
      [[ $# -lt 2 ]] && { err "--timeout requires a value such as 900s."; exit 2; }
      TEST_TIMEOUT="$2"; shift 2 ;;
    --launcher)
      [[ $# -lt 2 ]] && { err "--launcher requires xcodebuild or flutter."; exit 2; }
      LAUNCHER="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; PASSTHROUGH+=("$@"); break ;;
    *)                   err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
case "$LAUNCHER" in
  xcodebuild|flutter) ;;
  *) err "--launcher must be xcodebuild or flutter (got '$LAUNCHER')."; exit 2 ;;
esac
# The wipe opt-in only reaches keychain_accessibility_test.dart through the
# --all aggregate. Passed alone it defined nothing and said nothing, and an
# operator who typed it on purpose was left believing the suite had run.
if [[ "$ALLOW_KEYCHAIN_WIPE" == "true" && "$RUN_ALL" != "true" ]]; then
  err "--allow-keychain-wipe does nothing without --all: keychain_accessibility_test.dart runs only in the mock-mode aggregate."
  exit 2
fi
# Everything after `--` is `flutter test` arguments, and only the flutter lane
# has a `flutter test` to give them to. The xcodebuild lane never referenced
# PASSTHROUGH, so `-- --plain-name "live BLE"` on the DEFAULT launcher was
# parsed, stored and silently dropped: the full suite ran unfiltered and said
# nothing. Refused rather than ignored.
if (( ${#PASSTHROUGH[@]} > 0 )) && [[ "$LAUNCHER" != "flutter" ]]; then
  err "arguments after -- are passed to \`flutter test\`, which only --launcher flutter runs."
  err "Re-run with: --launcher flutter -- ${PASSTHROUGH[*]}"
  exit 2
fi

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
# `pick_rc=$?` MUST be read from a plain `|| pick_rc=$?`, never from inside
# `if ! UDID="$(pick_ios_device …)"`: the `!` inverts the pipeline's status, so
# `$?` in that branch is always 0 — which made `exit "$pick_rc"` exit 0 with no
# phone attached, reporting a run that could not happen as a pass.
pick_rc=0
UDID="$(pick_ios_device "$DEVICE_ID")" || pick_rc=$?
if (( pick_rc != 0 )); then
  # Exit 2 only. The picker also exits 1 when `flutter devices --machine` could
  # not be parsed — a broken or missing flutter, or one printing a banner ahead
  # of the JSON — and that is a toolchain failure, not an absent phone.
  # Swallowing it made an unattended --if-present run report success while
  # nothing could have run at all.
  # 2 only, never 3: exit 3 is "a phone is here, but not the one --device
  # named", which is a mistake to report, not hardware to skip. Swallowing it
  # said "no phone; nothing to run" with a phone plugged in and exited 0.
  if [[ "$IF_PRESENT" == "true" && "$pick_rc" -eq 2 ]]; then
    warn "No paired iPhone; nothing to run (--if-present)."
    exit 0
  fi
  exit "$pick_rc"
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
# What the tree looked like BEFORE anything below touches it, so the check at
# the end reports only what the BUILD changed — not edits the developer had in
# progress, and not the entitlements file the strip case rewrites (and the
# restore puts back): snapshotting after the strip made every auto/strip run
# end with a false "the build changed tracked files" naming Runner.entitlements,
# training the reader to ignore the one check meant to catch real drift.
TREE_BEFORE="$(git status --porcelain -- ios macos .gitignore pubspec.lock)"

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

DEFINES=(
  --dart-define=LB_HARDWARE=true
  --dart-define=LB_MULTICAST_ENTITLED="$MULTICAST_ENTITLED"
)
[[ "$EXPECT_LAN" == "true" ]] && DEFINES+=(--dart-define=LB_EXPECT_LAN_DEVICES=true)
[[ -n "$LIVE_BLE_NAME" ]] && DEFINES+=(--dart-define=LB_LIVE_BLE_NAME="$LIVE_BLE_NAME")
[[ "$LIVE_BLE_ANY" == "true" ]] && DEFINES+=(--dart-define=LB_LIVE_BLE_ANY=true)

LOG_DIR="build/ios-device-tests"
mkdir -p "$LOG_DIR"

# The xcodebuild lane points ios/Flutter/Generated.xcconfig at the suite
# (FLUTTER_TARGET, DART_DEFINES). It is gitignored and Flutter rewrites it on
# every build, but an Xcode GUI build in between would otherwise build the
# test app instead of the real one — so put it back on exit.
XCCONFIG="ios/Flutter/Generated.xcconfig"
XCCONFIG_BACKUP=""
restore_xcconfig() {
  if [[ -n "$XCCONFIG_BACKUP" && -f "$XCCONFIG_BACKUP" ]]; then
    cp "$XCCONFIG_BACKUP" "$XCCONFIG"
    rm -f "$XCCONFIG_BACKUP"
    XCCONFIG_BACKUP=""
  fi
}
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() { restore_xcconfig; restore_entitlements; }
trap cleanup EXIT

# Wait until the phone is unlocked, because xcodebuild will not.
#
# Its preflight checks the lock state ONCE. A phone that auto-locks during the
# build — which takes a couple of minutes, and the default Auto-Lock is well
# under that — leaves xcodebuild parked on "Unlock <device> to Continue"
# forever: unlocking afterwards does not wake it, and the run has to be killed
# and started again. So the check happens here, where it can be repeated, and
# the build is already done by the time it matters.
#
# `devicectl` answers `passcodeRequired: false` for an unlocked phone. A device
# with no passcode at all answers the same way, which is the right answer for
# it too.
wait_for_unlock() {
  local waited=0 interval=5 limit="${LB_UNLOCK_WAIT:-600}"
  while true; do
    if ! xcrun devicectl device info lockState --device "$UDID" 2>/dev/null \
        | grep -q 'passcodeRequired: true'; then
      [[ "$waited" -gt 0 ]] && log "Thanks — $1 is unlocked; starting."
      return 0
    fi
    if [[ "$waited" -eq 0 ]]; then
      warn "UNLOCK $1 AND KEEP IT AWAKE."
      warn "Set Settings > Display & Brightness > Auto-Lock to Never for the"
      warn "run: xcodebuild checks the lock once and waits forever if it is"
      warn "locked at that moment, and answering the permission prompts needs"
      warn "the screen anyway."
    elif (( waited % 60 == 0 )); then
      warn "still locked after ${waited}s; waiting up to ${limit}s."
    fi
    if (( waited >= limit )); then
      err "$1 was still locked after ${limit}s; nothing was run."
      return 1
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
}

# The seconds in a `flutter test --timeout` value such as 900s or 15m, for
# xcodebuild's per-test allowance.
timeout_seconds() {
  local v="$1"
  case "$v" in
    *ms) echo $(( ${v%ms} / 1000 )) ;;
    *s)  echo "${v%s}" ;;
    *m)  echo $(( ${v%m} * 60 )) ;;
    *h)  echo $(( ${v%h} * 3600 )) ;;
    *)   echo "$v" ;;
  esac
}

# Runs one Dart suite on the phone; $1 is the file, the rest are defines.
run_suite() {
  local suite="$1"; shift
  local name; name="$(basename "$suite" .dart)"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local logfile="$LOG_DIR/$name-$stamp.log"

  if [[ "$LAUNCHER" == "flutter" ]]; then
    flutter test "$suite" -d "$UDID" --timeout "$TEST_TIMEOUT" "$@" \
      "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}" 2>&1 | tee "$logfile"
    return "${PIPESTATUS[0]}"
  fi

  if [[ -z "$XCCONFIG_BACKUP" && -f "$XCCONFIG" ]]; then
    XCCONFIG_BACKUP="$(mktemp)"
    cp "$XCCONFIG" "$XCCONFIG_BACKUP"
  fi
  # PROFILE, not debug, and that is load-bearing.
  #
  # A Flutter app built in debug mode calls `ptrace(PT_TRACE_ME)` on startup
  # and refuses to create its engine if that fails — "Cannot create a
  # FlutterEngine instance in debug mode without Flutter tooling or Xcode".
  # `xcodebuild test` does not attach a debugger, so a debug build dies on
  # launch there however the device is set up; it is Xcode.app and
  # `flutter run` that satisfy the check. Profile keeps the VM service and
  # the tooling this suite needs without the ptrace requirement. (Flutter's
  # own guide for running integration tests on real devices in CI says the
  # same thing, in release.)
  log "flutter build ios --config-only --profile -t $suite"
  if ! flutter build ios --config-only --profile -t "$suite" "$@" >"$logfile" 2>&1; then
    err "flutter build ios --config-only failed; see $logfile"
    return 1
  fi

  # Named the way the operator named it, falling back to the UDID.
  if ! wait_for_unlock "${DEVICE_ID:-$UDID}"; then
    return 1
  fi

  local bundle="$LOG_DIR/$name-$stamp.xcresult"
  local allowance; allowance="$(timeout_seconds "$TEST_TIMEOUT")"
  # The allowance below bounds only XCTest's synthesized pass/fail methods.
  # INTEGRATION_TEST_IOS_RUNNER runs the WHOLE Dart suite inside
  # +testInvocations — test enumeration, before any XCTest method exists —
  # with FLTIntegrationTestRunner spinning the runloop until results arrive,
  # and the Dart binding's default timeout is Timeout.none. So a hung Dart
  # test (a connect that never completes, RustLib.init stuck) hung
  # `xcodebuild test` forever, no .xcresult, and an unattended run never
  # came back. This is the bound the script owns: scripts/bounded-run.pl —
  # every Mac has perl, none has GNU timeout — which sends xcodebuild SIGTERM
  # when it fires (so the on-device host and the CoreDevice tunnel it spawned
  # are torn down and the .xcresult finishes writing), SIGKILL ten seconds
  # later if it is still there, and exits 142 either way. A bare alarm on the
  # process used to kill it outright and orphan the app on the phone: the
  # next run on the same UDID found the device busy. The grace is pinned on
  # the command line, not inherited: an LB_BOUNDED_GRACE left exported from
  # poking the selftest (which uses two seconds) would otherwise KILL
  # xcodebuild before the on-device host was torn down.
  #
  # The bound also covers xcodebuild's own build-and-install phase, and a
  # cold Profile build of the Rust core plus Flutter on a Mac mini can take
  # most of half an hour on its own — so the default is an hour, and a
  # LEGITIMATELY long first run is not killed as a hang.
  local suite_bound="${LB_SUITE_TIMEOUT:-3600}"
  log "xcodebuild test -scheme Runner -destination id=$UDID (log: $logfile)"
  # Only the lines a reader acts on reach the terminal: what the suite
  # measured, each test's verdict, and anything that went wrong. The full
  # log is in $logfile and the per-test record in the .xcresult bundle.
  local rc=0
  {
  LB_BOUNDED_GRACE=10 perl scripts/bounded-run.pl "$suite_bound" xcodebuild test \
      -workspace ios/Runner.xcworkspace \
      -scheme Runner \
      -configuration Profile \
      -destination "id=$UDID" \
      -only-testing:RunnerTests \
      -resultBundlePath "$bundle" \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance "$allowance" \
      -maximum-test-execution-time-allowance "$allowance" \
      -allowProvisioningUpdates \
      2>&1 | tee -a "$logfile" \
      | grep --line-buffered -E \
          '\[hardware\]|Test Case|Test Suite .*(passed|failed)|error:|\*\* TEST|Executed [0-9]+ test|xcodebuild: error|Failing tests|Testing failed|Unable to|Unlock .* to Continue|destination is not ready' \
      | grep --line-buffered -vE 'DVTDeveloperAccountManager|Xcode-Username' \
      | sed -u -E 's/^.*Unlock (.*) to Continue.*$/UNLOCK THE PHONE: xcodebuild is waiting until \1 is unlocked (it carries on by itself once it is)./'
    rc="${PIPESTATUS[0]}"
  } || true
  if (( rc == 142 )); then
    err "xcodebuild test exceeded ${suite_bound}s (LB_SUITE_TIMEOUT) and was stopped: a test on the phone never completed. See $logfile"
    return 1
  fi
  # The `|| true` MUST stay outside the group and the read of PIPESTATUS MUST
  # stay inside it. `cmd | … || true` runs `true`, which is itself a pipeline,
  # and that overwrites PIPESTATUS with (0) before the next line can read it —
  # so `rc` was always 0 and a failing xcodebuild run was reported as a pass.
  # Only the `grep` below stood between a red hardware suite and "All device
  # suites passed", and a failing XCTest run still prints `Test Case '-[…`, so
  # it did not stand there at all.
  if ! grep -q "Test Case '-\[RunnerTests " "$logfile"; then
    if grep -q "Unlock .* to Continue" "$logfile"; then
      err "The phone stayed locked, so no test ran. Unlock it and run again; see $logfile"
    else
      err "No Dart test reached XCTest (the app may not have launched); see $logfile"
    fi
    return 1
  fi
  return "$rc"
}

status=0

log "Hardware suite: integration_test/device_hardware_test.dart"
log "(watch the phone: a fresh install raises the Bluetooth and Local Network alerts, and the suite waits for you to answer them)"
if ! run_suite integration_test/device_hardware_test.dart "${DEFINES[@]}"; then
  err "Hardware suite failed."
  status=1
fi

if [[ "$RUN_ALL" == "true" ]]; then
  log "CI aggregate in mock mode: integration_test/ci_all_test.dart"
  # keychain_accessibility_test.dart's fresh-install case runs the store's
  # sweep — deleteAll, no accessibility constraint — against THIS phone's
  # keychain, which outlives the app: on a phone the operator has used the
  # shipping app on, that is their credentials. The suite refuses a physical
  # iPhone unless LB_KEYCHAIN_WIPE_OK is defined, and only this flag defines it.
  wipe_define=()
  if [[ "$ALLOW_KEYCHAIN_WIPE" == "true" ]]; then
    warn "--allow-keychain-wipe: keychain_accessibility_test.dart WILL DELETE every keychain item under ca.pigscanfly.liberatedbread on this phone."
    wipe_define=(--dart-define=LB_KEYCHAIN_WIPE_OK=true)
  else
    log "keychain_accessibility_test.dart will skip on the phone (its fresh-install case wipes the app's keychain); pass --allow-keychain-wipe on a phone whose credentials are disposable."
  fi
  if ! run_suite integration_test/ci_all_test.dart --dart-define=LIBERATED_BREAD_MOCK=true "${wipe_define[@]+"${wipe_define[@]}"}"; then
    err "Mock-mode aggregate failed on the device."
    status=1
  fi
fi

restore_xcconfig
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
