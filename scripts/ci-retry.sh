#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run a command, retrying with exponential backoff. For network steps only.
#
# WHAT THIS IS FOR, AND WHAT IT IS NOT FOR
#
# Retrying a TEST hides the bug it just found, so nothing here is aimed at
# test flakiness — the two retries in this repo that do wrap a test run
# (scripts/ci-emulator-tests.sh, scripts/ci-ios-tests.sh) are each aimed at one
# diagnosed, documented device failure and each shout when they fire.
#
# This is for the other kind: a step whose only failure mode is somebody else's
# server having a bad second. `apt-get update` against a mirror that 503s, a
# crates.io fetch that resets mid-download. Those turn a green pull request red
# for reasons that have nothing to do with the change, and re-running the whole
# job to find out costs more than three seconds of backoff.
#
# Retries are announced, so a step that is quietly retrying every run — which
# means something is actually broken, not flaky — is visible in the log rather
# than hidden behind an eventual success.
#
# Usage:
#   ./scripts/ci-retry.sh <command> [args...]
#   LB_RETRY_ATTEMPTS=5 ./scripts/ci-retry.sh curl -fsSL https://example.com
#
# Environment:
#   LB_RETRY_ATTEMPTS   Total attempts, including the first (default 3).
#   LB_RETRY_DELAY      Seconds before the first retry (default 5). Doubles
#                       after each failure.

set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

attempts="${LB_RETRY_ATTEMPTS:-3}"
delay="${LB_RETRY_DELAY:-5}"

attempt=1
while : ; do
  "$@"
  status=$?

  [ "$status" -eq 0 ] && exit 0

  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error::\`$*\` failed after ${attempt} attempt(s) (exit ${status})." >&2
    exit "$status"
  fi

  echo "::warning::\`$*\` failed (exit ${status}); retrying in ${delay}s (attempt $((attempt + 1))/${attempts})." >&2
  sleep "$delay"
  delay=$((delay * 2))
  attempt=$((attempt + 1))
done
