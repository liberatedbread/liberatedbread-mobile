#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Report which vendored specs can actually drive a reading in the app.
#
# An entity renders only when its `state_characteristic` resolves to a
# characteristic with a `format:` block. Anything else shows as "cannot be
# decoded", which is a gap in the spec rather than in the app — this report is
# how you tell those two apart without installing anything.
#
# Usage:
#   scripts/spec_coverage.sh                        # markdown to stdout
#   scripts/spec_coverage.sh > coverage.md
#   scripts/spec_coverage.sh path/to/other/specs
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The real catalogue. examples/ holds only the fabricated test bulb, which
# would otherwise pad the coverage figures with a device nobody owns.
specs_dir="${1:-$repo_root/vendor/protocol-specs/device-specs/devices}"

if [[ ! -d "$specs_dir" ]]; then
  echo "no such spec directory: $specs_dir" >&2
  exit 1
fi
# Canonicalize before the cd below, or a relative argument that just passed
# the check above is re-resolved against rust/ and silently points elsewhere.
specs_dir="$(cd "$specs_dir" && pwd)"

# Uses the app's own parser, so the report and the app can never disagree.
cd "$repo_root/rust"
exec cargo run --quiet --example spec_coverage -- "$specs_dir"
