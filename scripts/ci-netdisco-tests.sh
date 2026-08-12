#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — run the local-network discovery suites against
# emulated devices on the real multicast groups.
#
# WHY THESE RUN ON THEIR OWN
#
# RealNetworkScanService talks to 224.0.0.251:5353 and 239.255.255.250:1900
# through `dart:io` sockets and package:multicast_dns. There is no plugin seam
# to substitute, so the only way to run that code is to put a responder on the
# wire — scripts/net_virtual_device.py — and then wait real seconds for real
# datagrams. Two things follow, and both are why this is not part of
# `flutter test`:
#
#   * It binds ports 5353 and 1900. A machine already running avahi-daemon or
#     systemd-resolved has 5353, and the whole suite would fail for a reason
#     that has nothing to do with the change under test.
#   * A scan window is seconds of waiting, not frames of a fake clock. The unit
#     suite is a minute for 700+ tests and should stay that way.
#
# So the tests carry @Tags(['netdisco']), the ordinary runs exclude that tag,
# and this script — its own CI job — is what opts in.
#
# WHY IT COLLECTS COVERAGE, AND INTO ITS OWN FILE
#
# This job is the ONLY place RealNetworkScanService executes, and the run that
# uploads coverage — the unit-tests job — is the one that excludes it. Measured
# on the same commit: that file is 108/169 lines (63.9%) in the uploaded report
# and 164/169 (97.0%) here. Fifty-six covered lines were being thrown away, so
# the best-tested service in the project read as the worst, a change to it
# looked like it was adding uncovered code, and improving these tests moved the
# number not at all.
#
# --coverage-path keeps it out of coverage/lcov.info: on CI these are separate
# runners and could not collide, but this script is meant to be runnable on a
# laptop, where clobbering the unit run's report would be a surprise. Codecov
# merges the two uploads for a commit, which is why two partial reports are
# fine — see the flags in .github/workflows/ci.yml and codecov.yml.
#
# Usage:
#   ./scripts/ci-netdisco-tests.sh
#
# Environment:
#   LB_TEST_TIMEOUT   Per-test timeout passed to `flutter test` (default 120s).
#   LB_COVERAGE_PATH  Where to write the lcov report
#                     (default coverage/netdisco-lcov.info).

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

TEST_TIMEOUT="${LB_TEST_TIMEOUT:-120s}"
COVERAGE_PATH="${LB_COVERAGE_PATH:-coverage/netdisco-lcov.info}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "::error::python3 is not installed; scripts/net_virtual_device.py is what the emulated devices run on." >&2
  exit 1
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# The whole suite, filtered by tag, rather than a hardcoded file list: a new
# netdisco-tagged suite is then picked up without editing this script.
#
# Serialized (--concurrency=1) because each suite spawns its own responder on
# the REAL 5353/1900, and SO_REUSEPORT means concurrent suites all hear each
# other: every responder answers every query, and a scan resolves a union of
# whichever scenarios happen to be up. The first two suites coexisted only
# because they run identical scenarios; the hub suite's bridge answers real
# HTTP and does not. Serial is also what the tag means — these tests spend
# real seconds on a real wire, one wire at a time.
flutter test --tags=netdisco --timeout "$TEST_TIMEOUT" --concurrency=1 \
  --coverage --coverage-path "$COVERAGE_PATH" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

# A tag typo, a renamed file, or an annotation that stopped parsing all produce
# the same thing: a green run that tested nothing. Refuse it — this job exists
# for exactly one suite, and "it passed" has to mean that suite ran.
if grep -qE 'No tests ran\.|No tests match the requested tag selectors' "$log"; then
  echo "::error::No netdisco-tagged test ran. The tag, the file, or the @Tags annotation moved." >&2
  exit 1
fi

# A passing run that produced no report uploads nothing, and Codecov's project
# status would then compare a report missing this job's lines against a base
# that had them — a coverage "drop" with no change behind it. Say so here
# rather than leaving it to be inferred from a percentage.
if [ "$status" -eq 0 ] && [ ! -s "$COVERAGE_PATH" ]; then
  echo "::error::The suite passed but ${COVERAGE_PATH} is missing or empty, so this job's coverage would not be uploaded." >&2
  exit 1
fi

exit "$status"
