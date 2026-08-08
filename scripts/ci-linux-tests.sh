#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — run the integration suites headlessly on the Linux
# desktop target, one `flutter test` invocation per file.
#
# WHY ONE FILE PER INVOCATION
#
# Passing the whole integration_test/ directory at once — the way the Android
# and iOS jobs do — does NOT work on the Linux desktop device. The first file
# passes, then flutter_tools reuses its VM-service connection for the next one
# and dies immediately with:
#
#   Bad state: Cannot add new events after calling close
#     dart:async/broadcast_stream_controller.dart 243:24
#     dart:io-patch/socket_patch.dart 2455:41  _Socket._onData
#
# That is flutter_tools closing the observatory socket when the first app exits
# and then still receiving data on it — a tooling bug, not an app bug. Verified
# locally: `flutter test integration_test -d linux` reports "+1 -1", while the
# very same file passes on its own in ~23s. A fresh invocation per file gives
# each a fresh connection, and buys per-suite process isolation that the device
# jobs' aggregate entrypoint gives up.
#
# WHICH FILES ARE SKIPPED, AND WHY IT IS TWO CHECKS AND NOT ONE
#
#   * ci_all_test.dart is the device jobs' aggregate of the very files this
#     loop iterates. Running it here would execute every suite twice, in one
#     process, which is exactly what this loop exists not to do.
#   * A file whose tests are ALL excluded by --exclude-tags=e2e (today:
#     e2e_walkthrough_test.dart, which needs scripts/e2e_shot_server.py on the
#     host) must be SKIPPED, not failed.
#
# The e2e case gets two layers because the first attempt at it got burned. The
# primary check reads the @Tags(['e2e']) annotation out of the file, which is
# the exact mechanism the exclusion acts on — deterministic, no dependency on
# runner output. The output-grep is a fallback for a file that mixes tagged and
# untagged tests in a way the annotation scan cannot see, and it matches BOTH
# strings flutter test emits for the nothing-to-run case: the plain runner
# prints "No tests ran." while the -d linux device runner prints "No tests
# match the requested tag selectors". The first CI run of this step
# misclassified the excluded file as a failure over exactly that difference.
#
# Any other non-zero exit is a real failure, and every file still runs: one
# invocation reports every broken suite instead of stopping at the first.
#
# WHY THIS IS A FILE AND NOT AN INLINE `run:` BLOCK
#
# The same reason scripts/ci-emulator-tests.sh is: a 30-line shell program that
# only ever executes inside a CI job is a program nobody can debug. This one
# runs on any machine with the Linux desktop toolchain — `./scripts/setup.sh`
# provides it — so the loop, the skip rules and the failure collection can be
# exercised in seconds instead of in a 3-minute job.
#
# Usage:
#   ./scripts/ci-linux-tests.sh                     # every suite
#   LB_LINUX_TEST_FILES=integration_test/x_test.dart ./scripts/ci-linux-tests.sh
#
# Environment:
#   LB_LINUX_TEST_FILES   Space-separated files to run instead of globbing
#                         integration_test/. For reproducing one failure.
#   LB_TEST_TIMEOUT       Per-test BODY timeout passed to `flutter test`
#                         (default 1200s). Not a bound on the load phase —
#                         package:test_core hardcodes 12 minutes for that, and
#                         keeping the build out of it is the warm-up build
#                         step's job, not this script's.

set -uo pipefail

# Relative paths below are the repo's, not the caller's.
cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

TEST_TIMEOUT="${LB_TEST_TIMEOUT:-1200s}"

# `command -v` rather than trusting the runner image: without xvfb-run the GTK
# runner fails with a display error that reads like an app bug.
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "::error::xvfb-run is not installed. It supplies the virtual X display the GTK runner needs; install it (it is in LINUX_DESKTOP_PACKAGES) or run ./scripts/setup.sh." >&2
  exit 1
fi

# Read the file-level annotation the exclusion acts on. Newlines are folded
# first because `dart format` wraps a multi-entry @Tags across lines.
is_e2e_file() {
  tr '\n' ' ' < "$1" \
    | grep -qE "@Tags[[:space:]]*\([[:space:]]*(const[[:space:]]*)?(<[^>]*>[[:space:]]*)?\[[^]]*['\"]e2e['\"]"
}

if [ -n "${LB_LINUX_TEST_FILES:-}" ]; then
  # shellcheck disable=SC2206  # word splitting is how the list is passed
  targets=(${LB_LINUX_TEST_FILES})
else
  targets=(integration_test/*_test.dart)
fi

status=0
ran=0

for t in "${targets[@]}"; do
  echo "::group::$t"

  if [ "$(basename "$t")" = "ci_all_test.dart" ]; then
    echo "SKIP  $t (device-job aggregate — its imports each run individually here)"
    echo "::endgroup::"
    continue
  fi

  if is_e2e_file "$t"; then
    echo "SKIP  $t (file-level @Tags(['e2e']) — excluded by --exclude-tags=e2e)"
    echo "::endgroup::"
    continue
  fi

  log="$(mktemp)"
  if xvfb-run -a flutter test "$t" \
       -d linux \
       --exclude-tags=e2e \
       --timeout "$TEST_TIMEOUT" \
       --dart-define=LIBERATED_BREAD_MOCK=true 2>&1 | tee "$log"; then
    echo "PASS  $t"
    ran=$((ran + 1))
  elif grep -qE 'No tests ran\.|No tests match the requested tag selectors' "$log"; then
    echo "SKIP  $t (every test in it is excluded by --exclude-tags=e2e)"
  else
    echo "::error file=$t::Integration test failed on the Linux desktop."
    status=1
    ran=$((ran + 1))
  fi
  rm -f "$log"
  echo "::endgroup::"
done

# A loop that skipped everything is a green step that tested nothing, which is
# how a renamed directory or an over-eager skip rule would hide. Refuse it.
if [ "$ran" -eq 0 ]; then
  echo "::error::No integration suite actually ran. Every candidate was skipped — check the glob and the skip rules above." >&2
  exit 1
fi

exit "$status"
