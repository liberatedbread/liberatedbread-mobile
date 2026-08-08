#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Make sure the PINNED flutter_rust_bridge_codegen is on PATH, and do nothing
# if it already is.
#
# WHY THE "do nothing" HALF MATTERS
#
# Building this thing from source costs about 90 seconds, on the job that gates
# every other job in the workflow. `cargo install` decides whether to rebuild by
# reading ~/.cargo/.crates.toml, which is cargo's bookkeeping — not the binary.
# Restore the binary from a cache without that file and cargo cheerfully builds
# it again, having been handed the finished article.
#
# So the check here is on the ARTIFACT: run it, read its version, and skip when
# it already matches. That is what lets the workflow cache exactly one file
# (~/.cargo/bin/flutter_rust_bridge_codegen, keyed on the pinned version) and
# have the cache actually save the 90 seconds.
#
# It replaces a bare `cargo install` that relied on Swatinem/rust-cache having
# swept up ~/.cargo/bin as part of its snapshot. That worked until it didn't:
# a cancelled run published a snapshot taken BEFORE the install, rust-cache
# will not overwrite an existing key, and every later run then "hit" that cache
# and rebuilt from source anyway — 89s, silently, for as long as the key lived.
# A cache whose key is the version and whose content is the one binary cannot
# fail that way: either the file is there and correct, or there is nothing to
# restore.
#
# Usage:
#   ./scripts/ci-install-frb.sh            # version from ci.yml
#   FRB_VERSION=2.9.0 ./scripts/ci-install-frb.sh

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SELF_DIR/.." || exit 1

# ci.yml is the pin's only home; the workflow exports FRB_VERSION into the
# step's environment, and a developer running this by hand gets the same value
# read out of the same file.
if [ -z "${FRB_VERSION:-}" ]; then
  # shellcheck source=ci-versions.sh
  source "$SELF_DIR/ci-versions.sh"
  FRB_VERSION="$CI_FRB_VERSION"
fi

installed=""
if command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  installed="$(flutter_rust_bridge_codegen --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi

if [ "$installed" = "$FRB_VERSION" ]; then
  echo "flutter_rust_bridge_codegen ${FRB_VERSION} already installed; skipping the build."
  exit 0
fi

if [ -n "$installed" ]; then
  echo "flutter_rust_bridge_codegen ${installed} is installed but ${FRB_VERSION} is pinned; rebuilding."
else
  echo "flutter_rust_bridge_codegen is not installed; building ${FRB_VERSION} (~90s)."
fi

# Through ci-retry.sh: this reaches crates.io, and a reset mid-download should
# not redden a pull request that has nothing to do with it.
exec "$SELF_DIR/ci-retry.sh" cargo install --locked "flutter_rust_bridge_codegen@${FRB_VERSION}"
