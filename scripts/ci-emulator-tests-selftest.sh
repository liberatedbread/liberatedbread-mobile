#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drives scripts/ci-emulator-tests.sh against a stub `flutter` and a stub
# `adb`, so the retry logic — the whole reason that file exists — is asserted
# on a laptop in seconds instead of only inside a 40-minute emulator job.
#
# The case worth having a test for is the one the script was written for and
# did not actually handle: an attempt that HANGS. `timeout` on its own sends a
# single SIGTERM and then waits forever, so a `flutter test` wedged on a VM
# service that never appeared (which is exactly the diagnosed failure the retry
# targets) sat through the TERM, `timeout` never returned, and the job died on
# its own timeout-minutes with no second attempt. --kill-after is what turns
# that back into a bounded attempt plus a retry; the first check below is a
# process that ignores SIGTERM, and it can only pass if the escalation happens.
#
# Needs a GNU `timeout` (as `timeout` or `gtimeout`), which is what the script
# under test calls. The Ubuntu runner has one; a stock macOS does not, so the
# hang check SKIPS there rather than failing — the retry cases below still run.
#
# Runs in scripts/test.sh and CI's gate job; needs bash only.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

status=0
# Counted, because every assertion in this file is behind a `command -v
# timeout` gate and both else-arms only skip. On a stock macOS — which has
# neither `timeout` nor `gtimeout`, and which is where scripts/test.sh tells a
# maintainer to "mirror CI before you're done" — the whole file used to print
# "all passed" having asserted precisely nothing.
checks=0
pass() { checks=$((checks + 1)); printf '  ok    %s\n' "$1"; }
fail() { checks=$((checks + 1)); printf '  FAIL  %s\n' "$1" >&2; status=1; }
skip() { printf '  skip  %s\n' "$1"; }

BIN="$(mktemp -d)"
WORK="$(mktemp -d)"
# The script writes its device log into the repo root (gitignored). Clean up
# whatever this run creates, and nothing else.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
  rm -rf "$BIN" "$WORK"
  rm -f emulator-logcat.txt emulator-logcat-attempt1.txt emulator-logcat-attempt2.txt
}
trap cleanup EXIT

# `adb logcat -c` and `adb logcat -v time` are all the script asks of adb. The
# second must keep running until it is killed, or stop_logcat's `wait` has
# nothing to wait for.
cat > "$BIN/adb" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = "-c" ]; then exit 0; fi
exec sleep 600
STUB

# The stub flutter's behaviour is $STUB_MODE:
#   hang  — ignore SIGTERM and sit there, the failure this script exists for
#   pass  — exit 0
#   flaky — fail once, then pass (the attempt counter lives in $STUB_STATE)
cat > "$BIN/flutter" <<'STUB'
#!/usr/bin/env bash
case "${STUB_MODE:-pass}" in
  hang)
    echo "$$" > "$STUB_STATE/hung.pid"
    trap 'echo "stub flutter: ignoring SIGTERM"' TERM
    # Short sleeps in a loop, not one long one: bash runs a trap only between
    # commands, so a single `sleep 600` would swallow the TERM report.
    for _ in $(seq 1 600); do sleep 1; done
    exit 0 ;;
  flaky)
    n=0
    [ -f "$STUB_STATE/attempts" ] && n="$(cat "$STUB_STATE/attempts")"
    n=$((n + 1))
    echo "$n" > "$STUB_STATE/attempts"
    [ "$n" -ge 2 ] && exit 0
    echo "stub flutter: failing attempt $n"
    exit 1 ;;
  *)
    exit 0 ;;
esac
STUB
chmod +x "$BIN/adb" "$BIN/flutter"

# The script calls `timeout` by name. A Mac with Homebrew coreutils has it as
# gtimeout only; bridge that rather than skipping a machine that does have a
# real one.
if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexec gtimeout "$@"\n' > "$BIN/timeout"
  chmod +x "$BIN/timeout"
fi

export PATH="$BIN:$PATH"
export STUB_STATE="$WORK"

# Run the script under test with an outer bound of its own, so a regression
# that reintroduces the unbounded wait FAILS here instead of hanging this
# script too. Prints the run's output to $WORK/out and returns its status, or
# 99 if the outer bound fired.
run_script() { # seconds
  local bound="$1"
  ( ./scripts/ci-emulator-tests.sh > "$WORK/out" 2>&1 ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$bound" ] && { kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 99; }
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# ── a hung attempt is killed, and the retry still happens ───────────────────
if command -v timeout >/dev/null 2>&1; then
  rm -f "$WORK/hung.pid"
  STUB_MODE=hang \
  ANDROID_EMULATOR_ATTEMPT_TIMEOUT=2s \
  LB_EMULATOR_KILL_GRACE=1s \
  LB_EMULATOR_ATTEMPTS=2 \
    run_script 40
  rc=$?
  if [ "$rc" -eq 99 ]; then
    fail "a SIGTERM-ignoring attempt must not hang the script (no --kill-after?)"
    # The outer bound killed the wrapper, not what it was waiting on.
    pkill -KILL -f 'ci-emulator-tests.sh' 2>/dev/null
    [ -f "$WORK/hung.pid" ] && kill -KILL "$(cat "$WORK/hung.pid")" 2>/dev/null
  else
    pass "a SIGTERM-ignoring attempt is bounded"
    if grep -q 'attempt timeout with no result' "$WORK/out"; then
      pass "the timeout is reported as a timeout, not as a test failure"
    else
      fail "exit $rc was not recognised as a timeout; output said: $(tail -n 3 "$WORK/out" | tr '\n' ' ')"
    fi
    if grep -q 'attempt 2/2' "$WORK/out"; then
      pass "the retry runs after a hung attempt"
    else
      fail "no second attempt after a hung one"
    fi
    hung="$(cat "$WORK/hung.pid" 2>/dev/null || true)"
    if [ -n "$hung" ] && kill -0 "$hung" 2>/dev/null; then
      fail "the hung attempt survived the timeout (pid $hung still running)"
      kill -KILL "$hung" 2>/dev/null
    else
      pass "the hung attempt is gone once the timeout fires"
    fi
  fi
else
  skip "hang case needs a GNU timeout (install coreutils); CI has one"
fi

# ── the ordinary outcomes ───────────────────────────────────────────────────
if command -v timeout >/dev/null 2>&1; then
  STUB_MODE=pass ANDROID_EMULATOR_ATTEMPT_TIMEOUT=60s LB_EMULATOR_ATTEMPTS=2 \
    run_script 60
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "a passing attempt exits 0"
  else
    fail "a passing attempt exited $rc"
  fi

  rm -f "$WORK/attempts"
  STUB_MODE=flaky ANDROID_EMULATOR_ATTEMPT_TIMEOUT=60s LB_EMULATOR_ATTEMPTS=2 \
    run_script 60
  rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/attempts" 2>/dev/null)" = "2" ]; then
    pass "a failing attempt is retried and the pass is the result"
  else
    fail "expected a retry ending in success; exit $rc after $(cat "$WORK/attempts" 2>/dev/null) attempt(s)"
  fi

  # The failed attempt's device log must survive under its own name, or the
  # only record of the failure is overwritten by the retry.
  if [ -f emulator-logcat-attempt1.txt ]; then
    pass "the failed attempt's logcat is kept under its own name"
  else
    fail "emulator-logcat-attempt1.txt was not kept"
  fi
else
  skip "retry cases need a GNU timeout (install coreutils); CI has one"
fi

if [ "$status" -eq 0 ]; then
  if [ "$checks" -eq 0 ]; then
    echo "ci-emulator-tests selftest: 0 checks ran (no GNU timeout on this machine; install coreutils to exercise the retry logic)"
  else
    echo "ci-emulator-tests selftest: all $checks checks passed"
  fi
fi
exit "$status"
