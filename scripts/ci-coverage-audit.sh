#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Refuse a coverage report that is silently missing files.
#
# THE HOLE THIS CLOSES
#
# `flutter test --coverage` instruments the libraries a test actually IMPORTS.
# A file that no test reaches, directly or transitively, does not appear in
# lcov.info at all — it is not reported as 0%, it is absent. Absent means it is
# missing from the denominator too, so it contributes nothing to the percentage
# and no `project` status can see it.
#
# The consequence is the wrong way round from what anyone expects: adding an
# entirely untested file to lib/ does not lower coverage. It does not move it at
# all. The one number the repo gates on is computed over "the code somebody
# already wrote a test for", which is a tautology, not a measurement.
#
# lib/main.dart was living in that gap — the app's own entrypoint, executed by
# nothing, invisible to every report. It is covered now (test/main_test.dart);
# this script is what stops the next one taking its place.
#
# WHAT IT CANNOT SEE, said plainly
#
# A file on the allowlist below that later grows executable code but is STILL
# imported by no test stays exempt and unnoticed. The allowlist is checked in
# the other direction — an entry that starts appearing in the report is an
# error, because that means it has instrumentable lines and no longer belongs —
# so the list cannot rot silently while a file is tested. It can while a file is
# not. Keep the list short and read it when you add to it.
#
# Usage:
#   ./scripts/ci-coverage-audit.sh                       # coverage/lcov.info
#   ./scripts/ci-coverage-audit.sh a.info b.info         # union of several
#
# Several reports are unioned because the suites are split across CI jobs (see
# codecov.yml): a file reached only by the netdisco suites is absent from the
# unit run's report and present in that job's. Locally both exist and both can
# be passed; in CI the unit-tests job passes its own, so a netdisco-only library
# would need an allowlist entry saying so.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

reports=("$@")
[ "${#reports[@]}" -eq 0 ] && reports=(coverage/lcov.info)

# Files with nothing to instrument, which therefore never appear in a report no
# matter who imports them. Each needs a reason, and each is verified below to
# still have nothing.
ALLOWED_ABSENT=(
  # A bare `abstract class` of method signatures. The production implementation
  # (SecureSettingsStore) lives elsewhere and is covered there.
  'lib/services/settings_store.dart'
  # An abstract class plus `export` directives re-exporting the generated FRB
  # DTOs. No statement in it ever runs.
  'lib/services/spec_codec.dart'
)

# Generated output, ignored by codecov.yml for the reasons argued there. Keep
# the two lists in step: a path ignored for reporting has no business being
# demanded here.
SKIP_PREFIX='lib/src/rust/'

missing=()
stale_allowlist=()

covered_files="$(mktemp)"
trap 'rm -f "$covered_files"' EXIT

for report in "${reports[@]}"; do
  if [ ! -s "$report" ]; then
    echo "::error::Coverage report '$report' is missing or empty. Run flutter test --coverage first; auditing nothing would pass by default, which is the failure this script exists to prevent." >&2
    exit 1
  fi
  sed -n 's/^SF://p' "$report" >> "$covered_files"
done

is_covered() { grep -Fxq "$1" "$covered_files"; }

is_allowed() {
  local f="$1" a
  for a in "${ALLOWED_ABSENT[@]}"; do
    [ "$a" = "$f" ] && return 0
  done
  return 1
}

# Tracked files only: build output and anything untracked is not the app.
while IFS= read -r f; do
  case "$f" in "$SKIP_PREFIX"*) continue ;; esac
  if is_allowed "$f"; then
    # The allowlist claims this file has nothing to instrument. If a report
    # disagrees, the claim expired.
    is_covered "$f" && stale_allowlist+=("$f")
    continue
  fi
  is_covered "$f" || missing+=("$f")
done < <(git ls-files 'lib/*.dart' 'lib/**/*.dart' | sort)

status=0

if [ "${#missing[@]}" -gt 0 ]; then
  status=1
  echo "::error::${#missing[@]} file(s) under lib/ appear in NO coverage report, which means no test imports them — so they are absent from the percentage rather than counted as zero, and adding them lowered coverage by nothing:" >&2
  for f in "${missing[@]}"; do
    echo "::error file=$f::$f is not measured by any test. Import it from a test (even a smoke test), or — if it genuinely has no executable lines — add it to ALLOWED_ABSENT in scripts/ci-coverage-audit.sh with the reason." >&2
  done
fi

if [ "${#stale_allowlist[@]}" -gt 0 ]; then
  status=1
  for f in "${stale_allowlist[@]}"; do
    echo "::error file=$f::$f is on ALLOWED_ABSENT in scripts/ci-coverage-audit.sh, which claims it has no executable lines — but it is in the coverage report, so it does. Remove the entry; it is now measured like everything else." >&2
  done
fi

if [ "$status" -eq 0 ]; then
  total="$(git ls-files 'lib/*.dart' 'lib/**/*.dart' | grep -cv "^$SKIP_PREFIX")"
  echo "Coverage audit: all ${total} non-generated lib/ file(s) are measured (${#ALLOWED_ABSENT[@]} allowed absent)."
fi

exit "$status"
