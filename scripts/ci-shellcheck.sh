#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Lint every shell script in the repo, with the same settings CI uses.
#
# WHY THIS IS WORTH A CI STEP
#
# The CI logic in this repo deliberately lives in scripts/ rather than in
# `run:` blocks, so that it can be run on a laptop. That is the right trade,
# but it moves a growing pile of shell — the emulator retry, the simulator
# retry, the Linux per-file loop, the three bundle verifiers — out from under
# every other check in the project. Dart has `flutter analyze --fatal-infos`;
# Rust has `clippy -D warnings`; the shell had nothing.
#
# It was not hypothetical. The first run of this found scripts/run-ios.sh
# piping simctl's JSON into `python3 - <<'PY'`, where the heredoc overrides the
# pipe (SC2259) — so `pick_simulator` had never once worked, and the script it
# is in is the documented way to run the app on a simulator.
#
# Usage:
#   ./scripts/ci-shellcheck.sh
#
# Exclusions, and why each is not just noise-suppression:
#   SC1091  "not following sourced file" — shellcheck cannot resolve
#           `source "$SCRIPT_DIR/ci-versions.sh"` because the path is computed
#           at runtime. -x makes it follow what it can; the rest is a false
#           negative about a file this same run lints directly anyway.
#   SC2029  "expands on the client side" for `ssh "$HOST" "$@"` in
#           scripts/run-remote-mac.sh. Client-side expansion is what that call
#           wants — the arguments are built locally on purpose.

set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)" || exit 1

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "::error::shellcheck is not installed. Ubuntu/Debian: sudo apt-get install -y shellcheck. macOS: brew install shellcheck." >&2
  exit 1
fi

# Explicit list of roots rather than a repo-wide find: vendor/ carries a
# subtree of somebody else's shell, and third-party lint failures are not
# this project's to fix or to be blocked by.
targets=()
while IFS= read -r f; do
  targets+=("$f")
done < <(find scripts .claude -name '*.sh' -type f | sort)

if [ "${#targets[@]}" -eq 0 ]; then
  echo "::error::Found no shell scripts to lint — the layout moved and this check is silently passing." >&2
  exit 1
fi

echo "Linting ${#targets[@]} shell script(s) with $(shellcheck --version | awk '/^version:/ { print $2 }')"
shellcheck -x -e SC1091,SC2029 "${targets[@]}"
status=$?

if [ "$status" -eq 0 ]; then
  echo "All shell scripts pass shellcheck."
fi
exit "$status"
