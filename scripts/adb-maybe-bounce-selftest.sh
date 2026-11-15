#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drives scripts/adb-maybe-bounce.sh against a stub `adb`, so when it offers
# to restart the adb server, when it does, and what it tells its caller are
# asserted without an SDK or a phone. Then drives
# run-android-device-tests.sh through it, in a sandbox, to pin the retry: a
# phone a wedged server hid is found after the restart, and an unattended run
# with no phone still fails as it did before (exit 2, no restart).
#
# Runs in scripts/test.sh and CI's gate job; needs bash and python3 only.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The stub's state, under $STUB_STATE:
#   devices        `adb devices` body lines ("serial<TAB>state")
#   after-bounce   the devices file to install on `start-server`, if present:
#                  what a restart "finds"
#   calls          every invocation, one per line
#   rc.<verb>      exit status for that verb (install, push, start-server)
cat > "$WORK/adb" <<'STUB'
#!/usr/bin/env bash
S="$STUB_STATE"
echo "adb $*" >> "$S/calls"
verb="${1:-}"
[[ "$verb" == "-s" ]] && verb="${3:-}"
case "$verb" in
  devices)
    # What an older adb prints on stdout when it has to start a server: not
    # a device, and must not be counted as one.
    echo "* daemon not running; starting now at tcp:5037"
    echo "List of devices attached"
    cat "$S/devices" 2>/dev/null
    echo
    exit 0 ;;
  kill-server) exit 0 ;;
  start-server)
    [[ -f "$S/after-bounce" ]] && cp "$S/after-bounce" "$S/devices"
    exit "$(cat "$S/rc.start-server" 2>/dev/null || echo 0)" ;;
  install|push)
    rc="$(cat "$S/rc.$verb" 2>/dev/null || echo 0)"
    # A failing verb succeeds once the server has been restarted.
    grep -qx "adb start-server" "$S/calls" && rc=0
    exit "$rc" ;;
esac
echo "stub adb: unexpected args: $*" >&2
exit 99
STUB
chmod +x "$WORK/adb"

status=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }
check_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

# export each NAME=value argument (in the caller's subshell).
export_all() { local kv; for kv in "$@"; do export "${kv?}"; done; }

reset_state() {
  export STUB_STATE="$WORK/state.$RANDOM$RANDOM"
  mkdir -p "$STUB_STATE"
  : > "$STUB_STATE/devices"
  : > "$STUB_STATE/calls"
}
bounces() { grep -c '^adb kill-server$' "$STUB_STATE/calls"; }

export ADB="$WORK/adb" LB_ADB_SETTLE_SECS=0
# shellcheck source=adb-maybe-bounce.sh
source scripts/adb-maybe-bounce.sh

# Each case runs in a subshell, so LB_ADB_BOUNCED (exported by a bounce)
# never leaks into the next. Prints "<status> <bounces>"; stdin is
# /dev/null, so the default "ask" sees no terminal.
maybe() { # env assignments...
  ( unset LB_ADB_BOUNCED; export_all "$@"
    adb_maybe_bounce </dev/null 2>"$STUB_STATE/stderr"; echo "$? $(bounces)" )
}

# 1. A device is listed (even unauthorized): the server is answering, so a
# restart would not help and is not offered.
reset_state
printf 'R58M123\tunauthorized\n' > "$STUB_STATE/devices"
check_eq "a listed device: no bounce, caller does not retry" "1 0" "$(maybe LB_ADB_BOUNCE=yes)"
if grep -q 'R58M123' "$STUB_STATE/stderr"; then
  pass "...and the device list is shown"
else
  fail "the device list was not shown"
fi

# 2. The '* daemon ...' line adb prints when starting a server is not a device.
reset_state
if adb_has_devices; then
  fail "counted adb's '* daemon' line as a device"
else
  pass "adb's '* daemon' line is not a device"
fi

# 3. Nothing listed, not a terminal, default "ask": no prompt, no bounce.
reset_state
check_eq "no devices, unattended: no bounce" "1 0" "$(maybe LB_ADB_BOUNCE=ask)"
if grep -q 'Not a terminal' "$STUB_STATE/stderr"; then
  pass "...and says why, and how to do it unattended"
else
  fail "an unattended run did not say why it did not offer the restart"
fi

# 4. LB_ADB_BOUNCE=no never bounces.
reset_state
check_eq "LB_ADB_BOUNCE=no: no bounce" "1 0" "$(maybe LB_ADB_BOUNCE=no)"

# 5. LB_ADB_BOUNCE=yes, and the restart brings the phone back: retry.
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
check_eq "bounce brings a device up: caller retries" "0 1" "$(maybe LB_ADB_BOUNCE=yes)"
if grep -qx 'adb start-server' "$STUB_STATE/calls"; then
  pass "...after kill-server AND start-server"
else
  fail "bounced without start-server"
fi

# 6. The restart finds nothing: do not tell the caller to retry.
reset_state
check_eq "bounce finds nothing: caller does not retry" "1 1" "$(maybe LB_ADB_BOUNCE=yes)"

# 7. Offered once per run: a second failure after a bounce does not loop.
reset_state
check_eq "already bounced this run: not again" "1 0" "$(maybe LB_ADB_BOUNCE=yes LB_ADB_BOUNCED=1)"

# 8. The interactive prompt, on a real pty: "y" bounces, anything else not.
prompt() { # answer; prints "<status> <bounces>"
  python3 - "$1" <<'PY'
import os, pty, sys, time
answer = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c",
        "unset LB_ADB_BOUNCED LB_ADB_BOUNCE; source scripts/adb-maybe-bounce.sh; "
        "adb_maybe_bounce; echo \"RC=$?\""])
out = b""
deadline = time.time() + 10
sent = False
while time.time() < deadline:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
    if not sent and b"[y/N]" in out:
        os.write(fd, (answer + "\n").encode())
        sent = True
os.waitpid(pid, 0)
text = out.decode(errors="replace")
rc = text.split("RC=")[-1].split()[0] if "RC=" in text else "?"
print(rc if sent else "noprompt")
PY
}
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
check_eq "on a terminal, answering y bounces and retries" "0 1" "$(prompt y) $(bounces)"
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
check_eq "on a terminal, the default (Enter) does not bounce" "1 0" "$(prompt '') $(bounces)"

# 9. adb_retry_after_bounce: a failing install with no device visible is
# retried once after the bounce; with a device visible it is not retried.
reset_state
echo 1 > "$STUB_STATE/rc.install"
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
retry_install() { # prints the status of adb_retry_after_bounce
  ( unset LB_ADB_BOUNCED; export_all LB_ADB_BOUNCE=yes
    adb_retry_after_bounce "$ADB" -s R58M123 install -r x.apk 2>/dev/null; echo "$?" )
}
check_eq "a failed install is retried after a bounce" "0 2" \
  "$(retry_install) $(grep -c 'install' "$STUB_STATE/calls")"
reset_state
echo 1 > "$STUB_STATE/rc.install"
printf 'R58M123\tdevice\n' > "$STUB_STATE/devices"
check_eq "with the device visible, a failed install is not retried" "1 1 0" \
  "$(retry_install) $(grep -c 'install' "$STUB_STATE/calls") $(bounces)"

# 10. Run directly: exit 0 when something is listed, 1 when nothing is even
# after a bounce, and --force bounces regardless.
standalone() { ( unset LB_ADB_BOUNCED LB_ADB_BOUNCE
  ./scripts/adb-maybe-bounce.sh "$@" </dev/null >/dev/null 2>&1; echo "$? $(bounces)" ); }
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/devices"
check_eq "standalone: a listed device exits 0, no bounce" "0 0" "$(standalone)"
check_eq "standalone --force bounces anyway" "0 1" "$(standalone --force)"
reset_state
check_eq "standalone --yes with nothing found exits 1 after one bounce" "1 1" "$(standalone --yes)"
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
check_eq "standalone --yes exits 0 when the bounce finds a phone" "0 1" "$(standalone --yes)"

# 11. run-android-device-tests.sh, end to end in a sandbox: `flutter devices`
# sees no phone until the adb server is restarted.
sandbox="$WORK/sandbox"
mkdir -p "$sandbox/scripts" "$sandbox/flutter/bin" "$sandbox/sdk/platform-tools"
# The runner's final reinstall finds adb through find_adb, which prefers
# $ANDROID_HOME/platform-tools/adb over PATH. GitHub's runners set ANDROID_HOME
# to a real SDK, whose adb failed that reinstall, so point it at the stub.
cp "$WORK/adb" "$sandbox/sdk/platform-tools/adb"
cp scripts/run-android-device-tests.sh scripts/android-device-select.sh \
  scripts/adb-maybe-bounce.sh "$sandbox/scripts/"
printf 'regen_frb_bindings() { :; }\n' >"$sandbox/scripts/regen-bindings.sh"
printf 'regen_spec_index() { :; }\n' >"$sandbox/scripts/regen-spec-index.sh"
printf 'ensure_gradle_jdk() { :; }\n' >"$sandbox/scripts/ensure-gradle-jdk.sh"
cat >"$sandbox/flutter/bin/flutter" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  devices)
    if grep -q 'R58M123' "$STUB_STATE/devices"; then
      echo '[{"name":"Pixel","id":"R58M123","targetPlatform":"android-arm64","emulator":false}]'
    else
      echo '[]'
    fi ;;
  test) echo "flutter $*" >>"$STUB_STATE/calls" ;;
  build)
    mkdir -p build/app/outputs/flutter-apk
    : >build/app/outputs/flutter-apk/app-debug.apk ;;
esac
STUB
chmod +x "$sandbox/flutter/bin/flutter"
runner() { # env assignments... ; prints "<exit> <bounces> <suites run>"
  ( unset LB_ADB_BOUNCED LB_ADB_BOUNCE; export_all "$@"
    cd "$sandbox" && ANDROID_HOME="$sandbox/sdk" FLUTTER_HOME="$sandbox/flutter" \
      bash scripts/run-android-device-tests.sh </dev/null >/dev/null 2>&1
    echo "$? $(bounces) $(grep -c '^flutter test' "$STUB_STATE/calls")" )
}
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
check_eq "device tests: a phone hidden by a wedged server is found after the bounce" \
  "0 1 1" "$(runner LB_ADB_BOUNCE=yes)"
reset_state
printf 'R58M123\tdevice\n' > "$STUB_STATE/after-bounce"
check_eq "device tests: unattended with no phone still exits 2, no bounce" \
  "2 0 0" "$(runner LB_ADB_BOUNCE=ask)"

if [[ "$status" -eq 0 ]]; then echo "adb-maybe-bounce selftest: all passed"; fi
exit "$status"
