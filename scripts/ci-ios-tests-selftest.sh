#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Drive scripts/ci-ios-tests.sh through every outcome of its retry loop, on any
# machine, in about twenty seconds.
#
# WHY THIS EXISTS
#
# ci-ios-tests.sh is the safety net for the most expensive job in CI, and the
# situations it exists for — a simulator that will not boot, an app that never
# launches — are ones nobody can produce on demand even ON a Mac. Left
# untestable, its logic is only ever exercised by the failure it is supposed to
# handle, at 10x, once, in a job that is already going badly.
#
# It got the treatment that predicts: the first version waited for the initial
# boot OUTSIDE the retry loop with an unbounded `simctl bootstatus -b`, so the
# single failure the retry most wanted to survive would have hung until the
# workflow step's timeout killed the whole thing — no erase, no retry, no log.
# A reviewer caught that by reading. This catches the next one by running.
#
# HOW
#
# Stub `xcrun` and `flutter` executables on PATH — real files, not shell
# functions, because `run_bounded` may exec through `timeout`, which cannot
# call a function. Each stub reads a mode from the environment and records what
# it was asked to do, so a case can assert on the erase-and-reboot actually
# happening rather than just on the exit code.
#
# The timeouts are set to seconds, so a "hang" resolves immediately.
#
# Usage:
#   ./scripts/ci-ios-tests-selftest.sh

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

BIN="$(mktemp -d)"
STATE="$(mktemp -d)"
trap 'rm -rf "$BIN" "$STATE"' EXIT

cat > "$BIN/xcrun" <<'STUB'
#!/usr/bin/env bash
# $1 is always "simctl" here; $2 is the subcommand.
case "$2" in
  bootstatus)
    case "$BOOT_MODE" in
      ok)   exit 0 ;;
      fail) exit 164 ;;               # a fast, non-zero refusal
      hang) sleep 300 ;;              # never returns; the bound must fire
      recover)                        # hangs once, then boots: the retry working
        n=$(cat "$STATE/boot" 2>/dev/null || echo 0)
        echo $((n + 1)) > "$STATE/boot"
        [ "$n" -ge 1 ] && exit 0 || sleep 300 ;;
    esac ;;
  list)  echo "  iPhone 99 (FAKE-UDID) (Booted)" ;;
  spawn) sleep 300 ;;                 # stands in for `log stream`
  erase|shutdown|boot) echo "simctl $2" >> "$STATE/actions" ;;
esac
exit 0
STUB

cat > "$BIN/flutter" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$STATE/tests" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STATE/tests"
case "$TEST_MODE" in
  pass)  echo "stub: tests passed"; exit 0 ;;
  fail)  echo "stub: tests failed"; exit 1 ;;
  hang)  sleep 300 ;;
  flaky) [ "$n" -ge 1 ] && exit 0 || exit 1 ;;
esac
STUB

chmod +x "$BIN/xcrun" "$BIN/flutter"
export PATH="$BIN:$PATH"
export STATE
export IOS_SIMULATOR_BOOT_TIMEOUT=3
export IOS_SIMULATOR_ATTEMPT_TIMEOUT=3
export LB_IOS_UDID=FAKE-UDID
export LB_IOS_ATTEMPTS=2

failures=0

# name, expected exit, expected erase count, BOOT_MODE, TEST_MODE
run_case() {
  local name="$1" want_exit="$2" want_erases="$3"
  export BOOT_MODE="$4" TEST_MODE="$5"
  rm -f "$STATE/boot" "$STATE/tests" "$STATE/actions"

  ./scripts/ci-ios-tests.sh --run >/dev/null 2>&1
  local got_exit=$?
  local got_erases
  got_erases="$(grep -c 'simctl erase' "$STATE/actions" 2>/dev/null || true)"
  got_erases="${got_erases:-0}"

  if [ "$got_exit" = "$want_exit" ] && [ "$got_erases" = "$want_erases" ]; then
    printf '  ok    %-32s exit=%-4s erases=%s\n' "$name" "$got_exit" "$got_erases"
  else
    printf '  FAIL  %-32s exit=%-4s (want %s)  erases=%s (want %s)\n' \
      "$name" "$got_exit" "$want_exit" "$got_erases" "$want_erases"
    failures=$((failures + 1))
  fi
}

echo "Exercising the ci-ios-tests.sh retry loop against stub xcrun/flutter:"

# The happy path must not erase anything — an erase on every green run would
# mean the retry is firing when nothing is wrong.
run_case "boot ok, tests pass"       0   0 ok      pass
run_case "boot ok, tests fail twice" 1   1 ok      fail
run_case "boot ok, tests flaky"      0   1 ok      flaky
# 124 is the bound firing. Without it a hang is indistinguishable from success
# in the exit code, which is how it would silently stop retrying.
run_case "tests hang"                124 1 ok      hang
# The two the reviewer found: both used to escape the loop entirely.
run_case "boot hangs"                124 1 hang    pass
run_case "boot fails fast"           164 1 fail    pass
# The one that proves the retry is worth having at all.
run_case "boot recovers after erase" 0   1 recover pass

if [ "$failures" -ne 0 ]; then
  echo "::error::${failures} ci-ios-tests.sh retry case(s) behaved unexpectedly." >&2
  exit 1
fi
echo "All ci-ios-tests.sh retry cases behaved as expected."
