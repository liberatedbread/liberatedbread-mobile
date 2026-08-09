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
# Usage:
#   ./scripts/ci-netdisco-tests.sh
#
# Environment:
#   LB_TEST_TIMEOUT   Per-test timeout passed to `flutter test` (default 120s).

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

TEST_TIMEOUT="${LB_TEST_TIMEOUT:-120s}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "::error::python3 is not installed; scripts/net_virtual_device.py is what the emulated devices run on." >&2
  exit 1
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# The whole suite, filtered by tag, rather than a hardcoded file list: a new
# netdisco-tagged suite is then picked up without editing this script.
flutter test --tags=netdisco --timeout "$TEST_TIMEOUT" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

# A tag typo, a renamed file, or an annotation that stopped parsing all produce
# the same thing: a green run that tested nothing. Refuse it — this job exists
# for exactly one suite, and "it passed" has to mean that suite ran.
if grep -qE 'No tests ran\.|No tests match the requested tag selectors' "$log"; then
  echo "::error::No netdisco-tagged test ran. The tag, the file, or the @Tags annotation moved." >&2
  exit 1
fi

exit "$status"
