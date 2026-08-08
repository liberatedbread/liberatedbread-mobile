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
# Usage:
#   ./scripts/ci-format.sh          # check; non-zero if anything is unformatted
#   ./scripts/ci-format.sh --write  # reformat in place

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

mode="${1:---check}"

files=()
while IFS= read -r f; do
  files+=("$f")
done < <(git ls-files '*.dart')

if [ "${#files[@]}" -eq 0 ]; then
  echo "::error::git ls-files found no tracked *.dart files. Either this is not the repository or the format check has silently become a no-op." >&2
  exit 1
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
  *)
    echo "usage: $0 [--check | --write]" >&2
    exit 2
    ;;
esac
