#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Proves the wall-clock bound scripts/run-ios-device-tests.sh puts on
# `xcodebuild test` — scripts/bounded-run.pl — does four things: lets a normal
# exit code through, stops a hang when it fires (TERM, then KILL), lets a
# command that handles TERM clean up first, and is what the runner actually
# wraps xcodebuild in.
#
# It exists because the runner's --timeout was DEAD in the default lane. The
# value became xcodebuild's per-test execution-time allowance, but
# INTEGRATION_TEST_IOS_RUNNER runs the whole Dart suite inside
# +testInvocations (test enumeration, before any XCTest method exists), the
# Dart binding's default timeout is Timeout.none, and the allowance bounds only
# the synthesized pass/fail methods. A hung Dart test hung `xcodebuild test`
# forever and an unattended run never came back. macOS has no GNU timeout, so
# the bound is perl — every Mac has it. The first shape was a bare alarm on
# the exec'd process, which killed xcodebuild outright and orphaned the app
# on the phone; the wrapper signals the process group instead.
#
# Runs in scripts/test.sh; needs bash and perl only.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

status=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }

check_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

bounded() { perl scripts/bounded-run.pl "$@"; }

# A command's own exit code passes through the bound untouched, both ways.
bounded 5 sh -c 'exit 7'
check_eq "a command's own exit code survives the bound" "7" "$?"
bounded 5 true
check_eq "success survives it" "0" "$?"

# A hang is killed when the alarm fires — 128 + SIGALRM(14) — and promptly.
# `alarm` is set in perl and must OUTLIVE the exec for this to work at all;
# that is a kernel guarantee (pending alarms survive execve), and this is
# where it is checked rather than trusted.
start=$SECONDS
bounded 1 sleep 30
rc=$?
elapsed=$((SECONDS - start))
check_eq "a hung command is killed when the bound fires (exit 142)" "142" "$rc"
if (( elapsed <= 5 )); then
  pass "...and within the bound (${elapsed}s for a 1s bound)"
else
  fail "the kill took ${elapsed}s for a 1s bound"
fi

# The bound is a TERM first, so the command can clean up, then a KILL. A
# child that traps TERM and leaves a note gets to; one that ignores TERM is
# killed anyway, ten seconds later. Both still read as 142 to the runner.
note="$(mktemp)"
rm -f "$note"
start=$SECONDS
bounded 1 bash -c "trap 'echo cleaned > \"$note\"; exit 0' TERM; sleep 30"
rc=$?
check_eq "a command that handles TERM is asked, not killed (still 142)" "142" "$rc"
if [[ -f "$note" ]]; then pass "...and it got to clean up"; else fail "the TERM never reached the command (no cleanup note)"; fi
rm -f "$note"
start=$SECONDS
bounded 1 bash -c "trap '' TERM; sleep 60"
rc=$?
elapsed=$((SECONDS - start))
check_eq "a command that ignores TERM is killed (142)" "142" "$rc"
if (( elapsed <= 16 )); then pass "...within the grace period (${elapsed}s)"; else fail "the KILL took ${elapsed}s after a 1s bound + 10s grace"; fi

# And the runner uses exactly this, on `xcodebuild test`, and treats the stop
# as a failure rather than as whatever grep made of the truncated log.
runner=scripts/run-ios-device-tests.sh
if grep -qE "^[[:space:]]*perl scripts/bounded-run\.pl \"\\\$suite_bound\" xcodebuild test" "$runner"; then
  pass "run-ios-device-tests.sh runs xcodebuild test under bounded-run.pl"
else
  fail "$runner: xcodebuild test is not run under \`perl scripts/bounded-run.pl \"\$suite_bound\"\`"
fi
if grep -qE '^[[:space:]]*if \(\( rc == 142 \)\); then' "$runner"; then
  pass "...and reports the kill as a failed suite"
else
  fail "$runner: exit 142 from the bound is not treated as a failure"
fi

if [[ "$status" -eq 0 ]]; then echo "run-ios-device-tests selftest: all passed"; fi
exit "$status"
