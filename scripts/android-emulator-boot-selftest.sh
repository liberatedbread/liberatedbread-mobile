#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drives boot_emulator and auto_fallback_emulator
# (scripts/android-emulator-boot.sh, behind run-android.sh's --emulator and
# its default auto mode) against stub `adb` and `emulator` binaries, so the
# choice of which emulator to wait for is asserted without an SDK. It exists because re-running run-android.sh while
# the AVD was still booting launched a second instance, which exits at once
# for an AVD in use, and the script died with "The emulator process exited
# before it booted." instead of waiting for the first.
#
# Runs in scripts/test.sh and CI's gate job; needs bash only. A few seconds.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# State the stubs share, one file each:
#   devices     `adb devices` body lines ("serial<TAB>state")
#   booted      serials whose sys.boot_completed is 1
#   avd.<ser>   the AVD name that serial's console answers with (absent:
#               no console, like a dead emulator adb still lists)
#   launch      what `emulator -avd` does: "in-use" (exit at once, like a
#               second launch of a running AVD), "in-use-late" (register
#               emulator-5554 offline, then exit), "boot" (register
#               emulator-5556 booted and stay up), "crash" (exit at once)
cat > "$WORK/adb" <<'STUB'
#!/usr/bin/env bash
S="$STUB_STATE"
if [[ "${1:-}" == "devices" ]]; then
  echo "List of devices attached"
  cat "$S/devices" 2>/dev/null
  exit 0
fi
if [[ "${1:-}" == "-s" ]]; then
  serial="$2"; shift 2
  case "$*" in
    "emu avd name")
      [[ -f "$S/avd.$serial" ]] || { echo "error: no console" >&2; exit 1; }
      printf '%s\r\nOK\r\n' "$(cat "$S/avd.$serial")"; exit 0 ;;
    "shell getprop sys.boot_completed")
      grep -qx "$serial" "$S/booted" 2>/dev/null && printf '1\r\n'
      exit 0 ;;
  esac
fi
echo "stub adb: unexpected args: $*" >&2
exit 99
STUB
cat > "$WORK/emulator" <<'STUB'
#!/usr/bin/env bash
S="$STUB_STATE"
if [[ "${1:-}" == "-list-avds" ]]; then echo liberated_bread_test; exit 0; fi
echo launched >> "$S/launches"
case "$(cat "$S/launch")" in
  in-use) exit 1 ;;
  in-use-late)
    printf 'emulator-5554\toffline\n' >> "$S/devices"
    echo liberated_bread_test > "$S/avd.emulator-5554"
    echo emulator-5554 >> "$S/booted"
    exit 1 ;;
  boot)
    printf 'emulator-5556\toffline\n' >> "$S/devices"
    echo liberated_bread_test > "$S/avd.emulator-5556"
    echo emulator-5556 >> "$S/booted"
    exec sleep 3 ;;
  crash) exit 1 ;;
esac
STUB
chmod +x "$WORK/adb" "$WORK/emulator"

# Read by the sourced library, which shellcheck does not follow from here.
# shellcheck disable=SC2034
ADB="$WORK/adb"
# shellcheck disable=SC2034
AVD_NAME="liberated_bread_test"
# shellcheck disable=SC2317,SC2329
log() { :; }
# shellcheck disable=SC2317,SC2329
err() { printf '%s\n' "$*" >&2; }
# shellcheck disable=SC2317,SC2329
find_emulator() { echo "$WORK/emulator"; }
export LB_EMULATOR_BOOT_TIMEOUT=3 LB_EMULATOR_POLL_SECS=1

# shellcheck source=android-emulator-boot.sh
source scripts/android-emulator-boot.sh

status=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }

# Fresh stub state; $1 is the launch behaviour.
reset_state() {
  export STUB_STATE="$WORK/state.$RANDOM"
  mkdir -p "$STUB_STATE"
  : > "$STUB_STATE/devices"
  echo "$1" > "$STUB_STATE/launch"
}

# Runs $1 (default boot_emulator) in a subshell (it exits on failure) and
# prints "<exit status> <BOOTED_SERIAL>".
run_boot() {
  ( "${1:-boot_emulator}" 2>"$STUB_STATE/stderr"; echo "0 $BOOTED_SERIAL" ) \
    || echo "$? -"
}
run_auto() { run_boot auto_fallback_emulator; }

launched() { [[ -f "$STUB_STATE/launches" ]]; }

check_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

# 1. This AVD is still booting (offline, console up) when the script runs.
reset_state in-use
printf 'emulator-5554\toffline\n' > "$STUB_STATE/devices"
echo liberated_bread_test > "$STUB_STATE/avd.emulator-5554"
echo emulator-5554 > "$STUB_STATE/booted"
check_eq "waits for this AVD's emulator that is still booting" \
  "0 emulator-5554" "$(run_boot)"
if [[ -f "$STUB_STATE/launches" ]]; then
  fail "launched a second instance of an AVD that was already starting"
else
  pass "does not launch a second instance of a starting AVD"
fi

# 2. The first instance registers only after the check and our launch loses:
# the new-serial diff picks it up.
reset_state in-use-late
check_eq "adopts an instance that registers after the launch" \
  "0 emulator-5554" "$(run_boot)"

# 2b. This AVD is already up ("device", so the pending check skips it and it
# is in the before-launch snapshot) and our launch loses to it. Only the
# attached_avd_emulator fallback finds it; without that this failed with
# "exited before it booted".
reset_state in-use
printf 'emulator-5554\tdevice\n' > "$STUB_STATE/devices"
echo liberated_bread_test > "$STUB_STATE/avd.emulator-5554"
echo emulator-5554 > "$STUB_STATE/booted"
check_eq "adopts an already-attached instance our launch lost to" \
  "0 emulator-5554" "$(run_boot)"
if launched; then
  pass "the already-attached case really launched and lost"
else
  fail "the already-attached case never launched, so it pins nothing"
fi

# 3. A stale offline entry with no console is not adopted: launch a new one.
reset_state boot
printf 'emulator-5554\toffline\n' > "$STUB_STATE/devices"
check_eq "launches past a stale offline emulator and waits for the new one" \
  "0 emulator-5556" "$(run_boot)"

# 4. The launch dies with nothing of this AVD attached: a real failure.
reset_state crash
check_eq "a crashed launch with nothing attached fails" "1 -" "$(run_boot)"
if grep -q "exited before it booted" "$STUB_STATE/stderr"; then
  pass "a crashed launch says the process exited"
else
  fail "a crashed launch did not say the process exited"
fi

# 5. Booting never finishes: fail at the timeout rather than carry on.
reset_state in-use
printf 'emulator-5554\toffline\n' > "$STUB_STATE/devices"
echo liberated_bread_test > "$STUB_STATE/avd.emulator-5554"
check_eq "an emulator that never boots fails at the timeout" "1 -" "$(run_boot)"

# 6. Auto mode (run-android.sh's default) re-run while this AVD is booting:
# the offline emulator is not "a phone that needs attention", so it waits
# rather than exit 1 telling the user to unplug an emulator.
reset_state in-use
printf 'emulator-5554\toffline\n' > "$STUB_STATE/devices"
echo liberated_bread_test > "$STUB_STATE/avd.emulator-5554"
echo emulator-5554 > "$STUB_STATE/booted"
check_eq "auto mode waits for this AVD's emulator that is still booting" \
  "0 emulator-5554" "$(run_auto)"
if launched || grep -q "OFFLINE" "$STUB_STATE/stderr"; then
  fail "auto mode launched again or called the booting emulator OFFLINE"
else
  pass "auto mode neither relaunches nor reports the booting emulator"
fi

# 7. Auto mode past a stale offline emulator entry: boot a new one.
reset_state boot
printf 'emulator-5554\toffline\n' > "$STUB_STATE/devices"
check_eq "auto mode launches past a stale offline emulator" \
  "0 emulator-5556" "$(run_auto)"

# 8. Auto mode with an offline PHONE: that is what the user meant, so say how
# to fix it and do not boot the emulator behind their back.
reset_state boot
printf 'R58M123\toffline\n' > "$STUB_STATE/devices"
check_eq "auto mode stops on an offline phone" "1 -" "$(run_auto)"
if ! launched && grep -q "R58M123 is attached but OFFLINE" "$STUB_STATE/stderr"
then
  pass "auto mode reports the offline phone without launching"
else
  fail "auto mode did not report the offline phone, or launched anyway"
fi

if [[ "$status" -eq 0 ]]; then echo "android-emulator-boot selftest: all passed"; fi
exit "$status"
