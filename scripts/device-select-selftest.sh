#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drives scripts/ios-device-select.sh and scripts/android-device-select.sh
# against a stub `flutter` whose `devices --machine` output is canned, so the
# one decision each picker makes — "is this a physical phone?" — is asserted
# without a phone, a simulator or Xcode. It exists because the iOS picker
# once offered a BOOTED simulator as "the first paired iPhone": a booted
# simulator reports targetPlatform "ios" like a phone does, and only the
# `emulator` field tells them apart.
#
# Runs in scripts/test.sh and CI's gate job; needs bash and python3 only.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

BIN="$(mktemp -d)"
trap 'rm -rf "$BIN"' EXIT

# The stub reads the JSON to print from $STUB_DEVICES.
cat > "$BIN/flutter" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "devices" ]]; then
  printf '%s\n' "$STUB_DEVICES"
  exit 0
fi
echo "stub flutter: unexpected args: $*" >&2
exit 99
STUB
chmod +x "$BIN/flutter"
export PATH="$BIN:$PATH"

# shellcheck source=ios-device-select.sh
source scripts/ios-device-select.sh
# shellcheck source=android-device-select.sh
source scripts/android-device-select.sh

MIXED='[
 {"name":"Dev16","id":"00008140-AAAA","targetPlatform":"ios","emulator":false,"sdk":"iOS 27.0"},
 {"name":"HK16","id":"00008140-BBBB","targetPlatform":"ios","emulator":false,"sdk":"iOS 26.6.1"},
 {"name":"iPhone 17","id":"B27BE477-SIM","targetPlatform":"ios","emulator":true,"sdk":"com.apple.CoreSimulator.SimRuntime.iOS-26-3"},
 {"name":"Pixel 8","id":"1A2B3C4D","targetPlatform":"android-arm64","emulator":false,"sdk":"Android 15 (API 35)"},
 {"name":"sdk gphone64 arm64","id":"emulator-5554","targetPlatform":"android-arm64","emulator":true,"sdk":"Android 14 (API 34)"},
 {"name":"macOS","id":"macos","targetPlatform":"darwin","emulator":false,"sdk":"macOS 26"}
]'
ONLY_SIMS='[
 {"name":"iPhone 17","id":"B27BE477-SIM","targetPlatform":"ios","emulator":true,"sdk":"sim"},
 {"name":"sdk gphone64 arm64","id":"emulator-5554","targetPlatform":"android-arm64","emulator":true,"sdk":"emu"}
]'

status=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }

check_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

export STUB_DEVICES="$MIXED"
check_eq "iOS: first phone, never a booted simulator" "00008140-AAAA" "$(pick_ios_device 2>/dev/null)"
check_eq "iOS: by name" "00008140-BBBB" "$(pick_ios_device HK16 2>/dev/null)"
check_eq "iOS: by UDID" "00008140-BBBB" "$(pick_ios_device 00008140-BBBB 2>/dev/null)"
if pick_ios_device "iPhone 17" >/dev/null 2>&1; then
  fail "iOS: a booted simulator must not be selectable by name"
else
  pass "iOS: a booted simulator is not selectable by name"
fi
if list_ios_devices | grep -q 'iPhone 17'; then
  fail "iOS: the listing must not show simulators"
else
  pass "iOS: the listing hides simulators"
fi
check_eq "Android: first phone, never an emulator" "1A2B3C4D" "$(pick_android_device 2>/dev/null)"
check_eq "Android: by name" "1A2B3C4D" "$(pick_android_device "Pixel 8" 2>/dev/null)"
if pick_android_device emulator-5554 >/dev/null 2>&1; then
  fail "Android: an emulator must not be selectable"
else
  pass "Android: an emulator is not selectable"
fi

export STUB_DEVICES="$ONLY_SIMS"
pick_ios_device >/dev/null 2>&1; check_eq "iOS: exit 2 when only simulators are up" "2" "$?"
pick_android_device >/dev/null 2>&1; check_eq "Android: exit 2 when only an emulator is up" "2" "$?"

# A NAMED device that is absent is not the same answer as no device at all:
# the runners let --if-present swallow exit 2, so if these shared one code,
# `--if-present --device HK16` with a different phone attached would print
# "no phone; nothing to run" and exit 0 on a suite that never ran.
export STUB_DEVICES="$MIXED"
pick_ios_device "NotHere" >/dev/null 2>&1
check_eq "iOS: exit 3 when the named phone is not the one attached" "3" "$?"
pick_android_device "NotHere" >/dev/null 2>&1
check_eq "Android: exit 3 when the named phone is not the one attached" "3" "$?"

export STUB_DEVICES='not json'
pick_ios_device >/dev/null 2>&1; check_eq "iOS: exit 1 on unparseable output" "1" "$?"

# The runners have to PROPAGATE those two exit codes, and there is one way to
# read them that silently cannot. `if ! VAR="$(pick_ios_device …)"; then` runs
# the picker, but bash's `!` inverts the pipeline status, so `$?` inside that
# branch is 0 no matter what the picker returned — `exit "$rc"` then exits 0
# with no phone attached and an unattended run reports a suite that never ran
# as a pass. The status has to come from a plain `|| pick_rc=$?` instead.
for runner in scripts/run-ios-device-tests.sh scripts/run-android-device-tests.sh; do
  if grep -qE '^\s*if ! [A-Z_]+="\$\(pick_(ios|android)_device' "$runner"; then
    fail "$runner: reads the picker through \`if ! VAR=\$(…)\`, where \$? is always 0"
  else
    pass "$(basename "$runner"): picker status is not read through \`if !\`"
  fi
  # Anchored to a real assignment, not just the string: both runners EXPLAIN
  # the rule in a comment that contains `|| pick_rc=$?` verbatim, so a bare
  # substring search passed on the prose alone and would have stayed green if
  # the capture itself were reverted.
  if grep -qE '^[A-Z_]+="\$\(pick_(ios|android)_device[^)]*\)" \|\| pick_rc=\$\?' "$runner"; then
    pass "$(basename "$runner"): picker status captured with || pick_rc=\$?"
  else
    fail "$runner: no \`VAR=\$(pick_..._device …) || pick_rc=\$?\` — the picker's exit code is not captured"
  fi
done

if [[ "$status" -eq 0 ]]; then echo "device-select selftest: all passed"; fi
exit "$status"
