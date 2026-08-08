#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — run the integration suite on a booted Android
# emulator, with a device log and a bounded retry.
#
# WHY THIS IS A FILE AND NOT A `script:` INPUT IN ci.yml
#
# reactivecircus/android-emulator-runner does not hand its `script:` input to a
# shell as a script. It splits the input on newlines and execs each line
# separately as `/usr/bin/sh -c '<line>'`. Two consequences, both of which we
# hit in CI before this file existed:
#
#   1. Nothing multi-line parses. A function definition, an `if`/`fi`, a `for`
#      loop — each is handed over one fragment at a time, so the shell reaches
#      end-of-input mid-construct:
#        [command]/usr/bin/sh -c run_tests() {
#        /usr/bin/sh: 1: Syntax error: end of file unexpected (expecting "}")
#   2. Nothing persists between lines. Each line is a fresh shell, so `set -u`
#      on line 1 does not apply to line 2, and a variable assigned on one line
#      is gone on the next.
#
# It is also /usr/bin/sh, which on the Ubuntu runner is dash — no `set -o
# pipefail`, no `[[`, no arrays. (`run:` blocks elsewhere in ci.yml default to
# bash and may use all of that; that input was the exception.)
#
# Putting the logic in an executable file with its own shebang gets all of it
# back: the workflow's `script:` input is now ONE line invoking this, bash reads
# the file as a whole, and the retry logic below is testable on a laptop
# instead of only in a 40-minute CI job.
#
# WHAT IT DOES
#
# Two attempts at the aggregate integration suite, each bounded by `timeout`,
# with the Android device log captured for both.
#
# The retry is aimed at a specific, diagnosed failure and not at flakiness in
# general: the app launching into an emulator that has not finished settling.
# The harness then hangs waiting for a VM service that never appears, prints
# NOTHING to the step log, and eventually eats the whole job timeout. `timeout`
# around each attempt is the load-bearing part — that failure hangs rather than
# exiting non-zero, so without a per-attempt bound there is no failure left to
# retry, only a killed step. Bounding each attempt turns a 60-minute red into a
# ~12-minute blip plus a green retry.
#
# By the time attempt 1 has burned its budget the emulator is long settled, so
# attempt 2 starts from the state attempt 1 wanted.
#
# A retry that passes still prints a ::warning:: and keeps both device logs. A
# flake that leaves no trace is a flake nobody fixes, and this one took a
# logcat diff against a passing run to explain in the first place.
#
# Usage:
#   ANDROID_EMULATOR_ATTEMPT_TIMEOUT=12m ./scripts/ci-emulator-tests.sh
#
# Environment:
#   ANDROID_EMULATOR_ATTEMPT_TIMEOUT   Required. Per-attempt wall clock, in
#                                      `timeout` syntax (e.g. 12m). Declared in
#                                      ci.yml's top-level env block; required
#                                      rather than defaulted here so renaming
#                                      it there fails with a name instead of
#                                      `timeout: invalid time interval ''`.
#   LB_EMULATOR_ATTEMPTS               Attempt count (default 2). Set to 1 to
#                                      reproduce a failure without waiting out
#                                      a retry.

set -u

# Relative paths below are the repo's, not the caller's.
cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

# No apostrophe in that message, deliberately: bash still does quote
# processing on the word inside ${VAR:?word}, so a lone ' opens a quote that
# never closes and the whole file fails to parse — at line 1, long before the
# check would ever run.
: "${ANDROID_EMULATOR_ATTEMPT_TIMEOUT:?must be set in the top-level env block of ci.yml}"
ATTEMPTS="${LB_EMULATOR_ATTEMPTS:-2}"

# ci_all_test.dart, NOT the integration_test directory: every file handed to
# `flutter test` on a device is its own kernel compile + native build + install
# + launch cycle, so the aggregate runs the same suites in one cycle. See
# docs/BUILD_AND_TEST.md.
TARGET="integration_test/ci_all_test.dart"
LOGCAT="emulator-logcat.txt"

logcat_pid=""

start_logcat() {
  adb logcat -c || true
  adb logcat -v time > "$LOGCAT" 2>&1 &
  logcat_pid=$!
}

stop_logcat() {
  [ -n "$logcat_pid" ] || return 0
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
  logcat_pid=""
}

# Don't leave logcat running when the script exits by any route, including the
# step being killed by its own timeout-minutes.
trap stop_logcat EXIT

run_tests() {
  # --exclude-tags=e2e is defence in depth. The e2e walkthrough stays out of
  # this run by omission (ci_all_test.dart does not import it — it needs
  # scripts/e2e_shot_server.py on the host, and 127.0.0.1 inside an emulator
  # reaches the emulator, not the host). The flag cannot filter a FILE-level
  # @Tags through an import, but it does filter a group- or test-level `tags:`
  # inside an imported suite.
  #
  # --timeout raises the per-test BODY timeout only — an emulator on
  # swiftshader with two cores is slow. It cannot extend the load phase, whose
  # 12-minute limit is hardcoded in package:test_core's synthetic load suite;
  # keeping loading inside that limit is the warm-up build step's job.
  timeout "$ANDROID_EMULATOR_ATTEMPT_TIMEOUT" \
    flutter test "$TARGET" \
      --exclude-tags=e2e \
      --timeout 1200s \
      --dart-define=LIBERATED_BREAD_MOCK=true
}

attempt=1
while : ; do
  echo "::group::Integration tests, attempt ${attempt}/${ATTEMPTS}"
  start_logcat

  # Capture the status directly, NOT via `if run_tests; then ... fi` followed
  # by `$?`: after an `if` whose branch was not taken, `$?` is the IF
  # statement's status (0), not the condition's — so a `timeout` kill reported
  # itself as "exit 0". Getting that wrong here would print a misleading exit
  # code for exactly the hang this retry exists for.
  run_tests
  status=$?

  stop_logcat
  echo "::endgroup::"

  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  if [ "$attempt" -ge "$ATTEMPTS" ]; then
    echo "::error::Integration tests failed on attempt ${attempt}/${ATTEMPTS} (exit ${status})."
    exit "$status"
  fi

  # 124 is `timeout`'s "I killed it" code — i.e. the hang above, not a test
  # that ran and reported failures. Worth naming, because the two look
  # identical in the step log: both produce no Dart output at all.
  if [ "$status" -eq 124 ]; then
    echo "::warning::Integration tests hit the ${ANDROID_EMULATOR_ATTEMPT_TIMEOUT} attempt timeout with no result — the known symptom of the app launching before the emulator settled. Retrying."
  else
    echo "::warning::Integration tests failed (exit ${status}). Retrying."
  fi

  # Keep this attempt's device log under its own name. It is the only place
  # that failure is visible, and the next attempt would otherwise append over
  # the top of it.
  mv "$LOGCAT" "emulator-logcat-attempt${attempt}.txt" || true
  attempt=$((attempt + 1))
done
