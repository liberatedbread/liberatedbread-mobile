#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Check (or apply) dart formatting over the Dart files this project owns.
#
# WHY NOT JUST `dart format .`
#
# Because it walks build/. Cargokit stages its own Dart program at
# build/linux/x64/debug/plugins/liberated_bread_core/cargokit_build/tool/bin/build_tool_runner.dart,
# and that file is not formatted to this project's satisfaction — so
# `dart format --set-exit-if-changed .` REFORMATS SOMEBODY ELSE'S VENDORED
# SOURCE and then fails because it changed something.
#
# CI never noticed: the analyze job runs the format check before anything is
# built, so build/ does not exist yet. Locally it always exists, because a
# developer runs the app. The result was `./scripts/test.sh` failing on a clean
# checkout for a file the developer has never seen, which is the exact
# green-in-CI-red-locally inversion that script exists to prevent — inverted.
#
# WHY `git ls-files` AND NOT A LIST OF DIRECTORIES
#
# Naming lib/ test/ integration_test/ tool/ would fix build/ and introduce a
# quieter bug: a new top-level Dart file, or a new directory, silently stops
# being formatted, and nothing says so. Asking git for the tracked *.dart files
# instead means the set is DERIVED from what is committed. Build output is
# gitignored, so it drops out for free, and nothing that is in the repository
# can escape the check without also being deleted from it.
#
# ...AND WHY rust_builder/ IS STILL EXCLUDED
#
# `git ls-files` answers with the tracked Dart, and 19 of those files are the
# SAME third-party program the paragraph above is about: cargokit's build_tool,
# vendored under rust_builder/cargokit/, every file of which opens with "This is
# copied from Cargokit". Staging a copy of it into build/ was never the problem
# — reformatting somebody else's source was, and this ran the formatter over the
# committed original while carefully avoiding the copy.
#
# It costs nothing today only because the vendored tree happens to satisfy the
# current formatter. The day it does not — a cargokit refresh, or a Dart
# formatter that changes its mind, as the 3.12 tall style did — `--write`
# rewrites vendored source and `--check` fails the build over a file this
# project must not touch. analysis_options.yaml already excludes
# `rust_builder/**` for the analyzer, for the same reason; this is the
# formatter's half of it.
#
# Usage:
#   ./scripts/ci-format.sh          # check; non-zero if anything is unformatted
#   ./scripts/ci-format.sh --write  # reformat in place
#   ./scripts/ci-format.sh --list   # print the file set, one per line

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

mode="${1:---check}"

# Vendored third-party Dart: excluded by path prefix, not by name, so a
# cargokit refresh that adds a file cannot quietly opt itself back in.
VENDORED_PREFIX="rust_builder/"

files=()
vendored=0
while IFS= read -r f; do
  case "$f" in
    "$VENDORED_PREFIX"*) vendored=$((vendored + 1)); continue ;;
  esac
  files+=("$f")
done < <(git ls-files '*.dart')

if [ "${#files[@]}" -eq 0 ]; then
  echo "::error::git ls-files found no tracked *.dart files outside ${VENDORED_PREFIX}. Either this is not the repository or the format check has silently become a no-op." >&2
  exit 1
fi

# Not silent: a vendored tree that stops being found (moved, un-vendored) is a
# thing to notice, and so is one that has grown. On stderr, so `--list` stays a
# list.
if [ "$vendored" -gt 0 ]; then
  echo "Skipping $vendored vendored Dart file(s) under ${VENDORED_PREFIX} — third-party source this project does not reformat." >&2
fi

case "$mode" in
  --write)
    echo "Formatting ${#files[@]} tracked Dart file(s)."
    dart format "${files[@]}"
    ;;
  --check)
    echo "Checking formatting of ${#files[@]} tracked Dart file(s)."
    dart format --set-exit-if-changed --output=none "${files[@]}"
    ;;
  --list)
    printf '%s\n' "${files[@]}"
    ;;
  *)
    echo "usage: $0 [--check | --write | --list]" >&2
    exit 2
    ;;
esac
