#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Asserts WHICH files scripts/ci-format.sh formats, which is the only thing
# about it that can go wrong quietly.
#
# Both failure directions are silent without this:
#
#   * Formatting somebody else's source. cargokit's build_tool is vendored
#     under rust_builder/ and says so in every file's first line; the format
#     check used to reformat it because `git ls-files '*.dart'` finds it. It
#     passed only because the vendored tree happened to satisfy the current
#     formatter — a cargokit refresh or a formatter change turns that into a
#     red build over a file this repo must not touch.
#   * Formatting nothing. An exclusion that over-matches, or a `git ls-files`
#     that stops matching, leaves a check that reports success over an
#     unexamined tree. ci-format.sh fails on an EMPTY set; it cannot notice a
#     set that lost a directory, so the shape of the set is asserted here.
#
# Runs in scripts/test.sh and CI's gate job; needs bash and git only.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

status=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; status=1; }

listed="$(./scripts/ci-format.sh --list 2>/dev/null)"

if [ -z "$listed" ]; then
  fail "--list printed nothing; the format check would be a no-op"
  exit 1
fi

# Vendored third-party Dart is out.
vendored="$(printf '%s\n' "$listed" | grep '^rust_builder/' || true)"
if [ -n "$vendored" ]; then
  fail "vendored Dart is in the format set: $(printf '%s\n' "$vendored" | head -n 1) (and $(printf '%s\n' "$vendored" | wc -l | tr -d ' ') file(s) in all)"
else
  pass "vendored cargokit Dart is not reformatted"
fi

# ...and it is genuinely there to be excluded. If cargokit moves, this selftest
# must stop claiming to guard something that no longer exists.
if [ -n "$(git ls-files 'rust_builder/*.dart')" ]; then
  pass "there is vendored Dart for the exclusion to exclude"
else
  fail "no tracked Dart under rust_builder/ — the exclusion in ci-format.sh guards nothing; delete both"
fi

# The app's own Dart is in. Named directories rather than a count, so adding a
# file cannot break it and losing a whole tree cannot pass.
for dir in lib test integration_test; do
  if printf '%s\n' "$listed" | grep -q "^$dir/"; then
    pass "$dir/ is formatted"
  else
    fail "$dir/ has dropped out of the format set"
  fi
done

# And the set is what the formatter is actually handed: --check reports the
# same count it listed.
counted="$(printf '%s\n' "$listed" | grep -c .)"
reported="$(./scripts/ci-format.sh --check 2>/dev/null | sed -n 's/^Checking formatting of \([0-9]*\) .*/\1/p')"
if [ "$counted" = "$reported" ]; then
  pass "--check formats the $counted file(s) --list names"
else
  fail "--list named $counted file(s) but --check reported '$reported'"
fi

if [ "$status" -eq 0 ]; then echo "ci-format selftest: all passed"; fi
exit "$status"
