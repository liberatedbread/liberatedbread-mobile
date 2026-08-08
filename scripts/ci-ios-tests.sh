#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — run the integration suite on an iOS simulator, with
# a device log, crash reports, and a bounded retry.
#
# WHY THIS EXISTS
#
# The iOS job is the most expensive thing in CI — macOS minutes bill at 10x —
# and until now it was also the only device job with NO retry and NO device
# diagnostics. The Android job has both, and it needed both: the settling race
# documented in scripts/ci-emulator-tests.sh was diagnosed by diffing a failing
# logcat against a passing one, and could not have been diagnosed without it.
#
# The iOS equivalents of that failure are real and were invisible here:
#
#   * The app fails to launch on the simulator (dyld cannot resolve an embedded
#     framework, the install is rejected, CoreSimulator is wedged). flutter_tools
#     then waits for a VM service that never appears and prints NOTHING to the
#     step log until the job times out. The evidence lives in the SIMULATOR's
#     log and its crash reports, neither of which was captured.
#   * The simulator itself never finishes booting, or boots into a state where
#     `simctl install` hangs. A fresh runner nearly always recovers on a second
#     try against an erased device — but there was no second try.
#
# So: capture the device log for every attempt, copy out any crash report the
# run produced, and give a failed attempt one retry against an ERASED, freshly
# booted simulator. A retry that passes still prints a ::warning:: and keeps
# both attempts' logs, because a flake that leaves no trace is a flake nobody
# fixes.
#
# The per-attempt wall-clock bound is the load-bearing part, exactly as it is
# on Android: the launch failures above HANG rather than exiting non-zero, so
# without a bound there is no failure left to retry — only a killed step and a
# 10x bill for the whole job timeout.
#
# WHY IT IS A FILE AND NOT AN INLINE `run:` BLOCK
#
# Same reason as scripts/ci-emulator-tests.sh: this is a shell program with
# state, cleanup and a retry loop, and one that only ever runs inside a
# 10-minute macOS job is one nobody can debug. On a Mac this runs as-is.
#
# Usage:
#   ./scripts/ci-ios-tests.sh --boot            # pick + start booting, print udid
#   LB_IOS_UDID=<udid> ./scripts/ci-ios-tests.sh --run
#   ./scripts/ci-ios-tests.sh                   # boot and run, for a laptop
#
# Environment:
#   IOS_SIMULATOR_ATTEMPT_TIMEOUT  Required by --run. Per-attempt wall clock in
#                                  seconds. Declared in ci.yml's top-level env
#                                  block; required rather than defaulted here so
#                                  renaming it there fails with a name instead
#                                  of silently running unbounded.
#   LB_IOS_UDID                    Simulator to use. Defaults to whatever
#                                  --boot picked, else the first available
#                                  iPhone.
#   LB_IOS_ATTEMPTS                Attempt count (default 2). Set to 1 to
#                                  reproduce a failure without waiting out a
#                                  retry.
#   LB_TEST_TIMEOUT                Per-test BODY timeout for `flutter test`
#                                  (default 1200s). NOT a bound on the load
#                                  phase — package:test_core hardcodes 12
#                                  minutes for that, and keeping the app build
#                                  outside it is the build step's job.

set -uo pipefail

# Relative paths below are the repo's, not the caller's.
cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

# ci_all_test.dart, NOT the integration_test directory: every file handed to
# `flutter test` on a device is its own kernel compile + Xcode build + install
# + launch cycle, ~2 minutes each on this runner with every cache warm. The
# aggregate collapses them into one. See docs/BUILD_AND_TEST.md.
TARGET="integration_test/ci_all_test.dart"
TEST_TIMEOUT="${LB_TEST_TIMEOUT:-1200s}"
LOG="ios-simulator-log.txt"
CRASH_DIR="ios-crash-reports"

# Both on stderr, deliberately: `--boot` prints the chosen UDID on stdout and
# `--all` reads it back with $(...), so a chatty stdout would hand the run mode
# a "UDID" with three lines of prose in front of it.
log()  { printf '\033[1;32m[ios-ci]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[ios-ci]\033[0m %s\n' "$*" >&2; }

# ── simulator selection ─────────────────────────────────────────────────────
# The first available iPhone in the runner image, rather than a pinned model:
# an Xcode image bump that retires a device name must not break the job.
#
# `simctl list devices available` prints "    iPhone 17 Pro (UDID) (Shutdown)",
# so the UDID is the first parenthesised field; `available` already filters out
# devices whose runtime is not installed.
pick_udid() {
  xcrun simctl list devices available \
    | awk -F'[()]' '/^ +iPhone/ { print $2; exit }'
}

require_udid() {
  local udid="${LB_IOS_UDID:-}"
  if [ -z "$udid" ]; then
    udid="$(pick_udid)"
  fi
  if [ -z "$udid" ]; then
    echo "::error::No iPhone simulator is available on this machine." >&2
    xcrun simctl list devices available >&2
    exit 1
  fi
  printf '%s' "$udid"
}

# ── the timeout, without depending on GNU coreutils ─────────────────────────
# macOS ships no `timeout`. The GitHub runner image usually has one via
# Homebrew coreutils (as `timeout` and/or `gtimeout`), but "usually" is not a
# thing to build the only bound on a 10x-billed job out of — and a developer's
# Mac very likely has neither.
#
# So: use a real `timeout` when there is one, and otherwise a watchdog that
# reproduces the part we depend on, including the exit code. 124 is `timeout`'s
# "I killed it", and the retry logic below distinguishes it from a test that
# ran and reported failures — the two look identical in a step log, since both
# produce no Dart output at all.
#
# --kill-after on both real-timeout paths, matching the TERM-then-KILL the
# fallback below already does. Without it `timeout` sends one TERM and then
# waits indefinitely for a process that, by the time this fires, is already not
# behaving — and an orphaned `flutter test` still holding the simulator is
# precisely what attempt 2 does not need. (GNU timeout does signal the whole
# process group by default, so the escalation is the part that was missing, not
# the reach.)
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=10 "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=10 "$secs" "$@"
    return $?
  fi

  # The marker is what makes the exit code truthful: a killed process reports
  # 143 (SIGTERM), which is indistinguishable from the runner being cancelled.
  # Only the watchdog creates this file, so its presence means "we did that".
  local marker
  marker="$(mktemp)"
  rm -f "$marker"

  "$@" &
  local pid=$!
  (
    sleep "$secs"
    if kill -0 "$pid" 2>/dev/null; then
      : > "$marker"
      # TERM first so flutter_tools can tear the app down; KILL if it will not.
      kill -TERM "$pid" 2>/dev/null
      sleep 10
      kill -KILL "$pid" 2>/dev/null
    fi
  ) &
  local watchdog=$!

  wait "$pid"
  local status=$?

  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null

  if [ -f "$marker" ]; then
    rm -f "$marker"
    return 124
  fi
  rm -f "$marker"
  return "$status"
}

# ── device log capture ──────────────────────────────────────────────────────
# Predicate-filtered rather than the firehose: an unfiltered `log stream` on a
# booted simulator is tens of MB per minute and buries the four processes that
# can actually explain a launch failure.
#
#   Runner              the app itself (Flutter's iOS target name)
#   SpringBoard         refuses or kills a launch
#   launchd_sim         reports the spawn and its failures
#   CoreSimulatorBridge the host side of install/launch
log_pid=""

start_log() {
  local udid="$1"
  # --style compact keeps one line per record. Failure here is not fatal: a
  # missing log makes diagnosis harder, not the test wrong.
  xcrun simctl spawn "$udid" log stream \
    --style compact \
    --predicate 'process == "Runner" OR process == "SpringBoard" OR process == "launchd_sim" OR process == "CoreSimulatorBridge"' \
    > "$LOG" 2>&1 &
  log_pid=$!
}

stop_log() {
  [ -n "$log_pid" ] || return 0
  kill "$log_pid" 2>/dev/null
  wait "$log_pid" 2>/dev/null
  log_pid=""
}

# Everything the host knows about a failed attempt, in two places because the
# two failures leave their evidence in different ones:
#
#   DiagnosticReports        a crash report names the missing symbol or dylib
#                            when the app dies before Dart ever runs — the
#                            failure the step log cannot show at all.
#   CoreSimulator/<udid>/    the device's own system log, which is where a boot
#                            that never completes is recorded. `simctl spawn
#                            log stream` cannot help there: it needs a booted
#                            device, which is precisely what is missing.
collect_diagnostics() {
  local dest="$1" udid="$2"
  mkdir -p "$dest"

  local reports="$HOME/Library/Logs/DiagnosticReports"
  if [ -d "$reports" ]; then
    # -newermt is not portable to BSD find; -name is enough, since a fresh
    # runner has no unrelated reports and a developer can tell theirs apart.
    find "$reports" -maxdepth 1 \( -name 'Runner*' -o -name 'liberated*' \) \
      -exec cp {} "$dest/" \; 2>/dev/null || true
  fi

  local simlogs="$HOME/Library/Logs/CoreSimulator/$udid"
  if [ -d "$simlogs" ]; then
    cp -R "$simlogs" "$dest/coresimulator-$udid" 2>/dev/null || true
  fi
}

# Don't leave a log stream running when the script exits by any route,
# including the step being killed by its own timeout-minutes.
trap stop_log EXIT

# ── modes ───────────────────────────────────────────────────────────────────
boot_async() {
  local udid
  udid="$(require_udid)"
  log "Booting simulator $udid in the background"
  # Non-zero when it is already booted, which is not an error here.
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  # Consumed by the `--run` step via LB_IOS_UDID.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "udid=$udid" >> "$GITHUB_OUTPUT"
  fi
  printf '%s\n' "$udid"
}

# Bring the device to a known-good, EMPTY state. Used before a retry: the most
# likely reason attempt 1 hung is a wedged install or a half-launched app, and
# erasing is the only reset that clears both.
#
# It START the boot and does not wait for it — waiting is wait_for_boot's job,
# inside the next attempt, where it is bounded. An unbounded `bootstatus -b`
# here would reintroduce exactly the hang this retry exists to survive.
reset_device() {
  local udid="$1"
  warn "Erasing and rebooting simulator $udid before the retry"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl erase "$udid" >/dev/null 2>&1 || true
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
}

# Block until the device is usable, or give up.
#
# `simctl bootstatus -b` has no timeout of its own, and "the simulator never
# finishes booting" is one of the two failures this whole script exists for —
# so an unbounded call is the one place the bound must not be missing. It is
# also why this lives INSIDE the attempt loop: a boot that fails or hangs has
# to reach the erase-and-retry path like any other failed attempt, not abort
# the step before the retry logic is ever entered.
#
# Its own budget, separate from the test attempt's: on the first attempt the
# boot was started minutes earlier by --boot and this returns at once, and a
# device that still is not up after IOS_SIMULATOR_BOOT_TIMEOUT is wedged rather
# than slow. Folding it into the test budget would let a slow boot eat the time
# the tests need.
wait_for_boot() {
  local udid="$1"
  run_bounded "$IOS_SIMULATOR_BOOT_TIMEOUT" xcrun simctl bootstatus "$udid" -b
}

run_tests() {
  local udid="$1"
  # --exclude-tags=e2e is defence in depth. The e2e walkthrough stays out of
  # this run by omission (ci_all_test.dart does not import it), and a FILE-level
  # @Tags cannot be filtered through an import — but a group- or test-level
  # `tags:` inside an imported suite IS registered at runtime and IS filtered
  # by this flag.
  #
  # -d is required, not optional: macOS runners also expose the macOS desktop
  # device, and `flutter test` refuses to run with more than one connected.
  #
  # --no-pub because the job's own `flutter pub get` step already ran; without
  # it every invocation re-resolves the whole dependency set.
  run_bounded "$IOS_SIMULATOR_ATTEMPT_TIMEOUT" \
    flutter test "$TARGET" \
      --no-pub \
      --exclude-tags=e2e \
      -d "$udid" \
      --timeout "$TEST_TIMEOUT" \
      --dart-define=LIBERATED_BREAD_MOCK=true
}

# Whole seconds, no suffix. `timeout 12m` is valid but `sleep 12m` is not on
# macOS, so a suffixed value would bound the run on a machine with coreutils and
# silently not bound it on one without — the two paths have to agree, and the
# only spelling both accept is a plain integer.
require_seconds() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "::error::${name} must be whole seconds with no unit suffix (got '${value}')." >&2
      exit 2
      ;;
  esac
}

run_mode() {
  : "${IOS_SIMULATOR_ATTEMPT_TIMEOUT:?must be set in the top-level env block of ci.yml}"
  : "${IOS_SIMULATOR_BOOT_TIMEOUT:?must be set in the top-level env block of ci.yml}"
  require_seconds IOS_SIMULATOR_ATTEMPT_TIMEOUT "$IOS_SIMULATOR_ATTEMPT_TIMEOUT"
  require_seconds IOS_SIMULATOR_BOOT_TIMEOUT "$IOS_SIMULATOR_BOOT_TIMEOUT"

  local attempts="${LB_IOS_ATTEMPTS:-2}"
  local udid
  udid="$(require_udid)"

  local attempt=1
  while : ; do
    echo "::group::Integration tests on the simulator, attempt ${attempt}/${attempts}"

    # The boot wait is INSIDE the loop, and bounded. It used to sit in front of
    # the loop as a plain `bootstatus -b`, which got both halves of its own
    # premise wrong: a boot that hangs is one of the two failures this retry
    # exists for, and there it would have hung unbounded until the workflow
    # step's timeout killed the whole thing — no erase, no retry, no log. A
    # boot that failed fast was no better: it exited before the retry path.
    #
    # On the first attempt --boot started this device minutes ago, so this
    # normally returns immediately.
    log "Waiting for simulator $udid to finish booting"
    wait_for_boot "$udid"
    local status=$?

    if [ "$status" -eq 0 ]; then
      # Only now: `simctl spawn … log stream` needs a booted device, so
      # starting it any earlier gets an error instead of a log. The boot
      # failure's own evidence comes from collect_diagnostics below, which
      # reads the device's system log off the host.
      start_log "$udid"

      # Capture the status directly, NOT via `if run_tests; then ... fi`:
      # after an `if` whose branch was not taken, `$?` is the IF statement's
      # status (0), not the condition's — so a watchdog kill would report
      # itself as "exit 0", which is exactly the hang this retry exists for.
      run_tests "$udid"
      status=$?
      stop_log
    elif [ "$status" -eq 124 ]; then
      echo "::error::Simulator $udid did not finish booting within ${IOS_SIMULATOR_BOOT_TIMEOUT}s." >&2
      xcrun simctl list devices >&2
    else
      echo "::error::Simulator $udid failed to reach a booted state (exit ${status})." >&2
      xcrun simctl list devices >&2
    fi

    echo "::endgroup::"

    if [ "$status" -eq 0 ]; then
      exit 0
    fi

    collect_diagnostics "$CRASH_DIR" "$udid"

    if [ "$attempt" -ge "$attempts" ]; then
      echo "::error::Integration tests failed on the simulator, attempt ${attempt}/${attempts} (exit ${status})." >&2
      exit "$status"
    fi

    if [ "$status" -eq 124 ]; then
      echo "::warning::Attempt ${attempt} hit its timeout with no result — the symptom of an app that never launched or a wedged simulator. Retrying on an erased device."
    else
      echo "::warning::Attempt ${attempt} failed (exit ${status}). Retrying on an erased device."
    fi

    # Keep this attempt's device log under its own name; the next attempt would
    # otherwise write over the only record of what went wrong.
    mv "$LOG" "ios-simulator-log-attempt${attempt}.txt" 2>/dev/null || true

    reset_device "$udid"
    attempt=$((attempt + 1))
  done
}

# Executed: dispatch. Sourced: define the functions and do nothing, so the
# pieces that do not need a Mac — run_bounded above, in particular, which is
# the only thing bounding a 10x-billed job when the runner image has no
# coreutils — can be exercised from a test harness on any machine. The same
# split scripts/ci-versions.sh uses.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:---all}" in
    --boot) boot_async ;;
    --run)  run_mode ;;
    --all)  LB_IOS_UDID="$(boot_async)" run_mode ;;
    *)
      echo "usage: $0 [--boot | --run | --all]" >&2
      exit 2
      ;;
  esac
fi
