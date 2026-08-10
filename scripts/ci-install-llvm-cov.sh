#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Make sure the PINNED cargo-llvm-cov is on PATH, and do nothing if it already
# is. The sibling of scripts/ci-install-frb.sh, for the same reasons and with
# the same shape — read that file's header for the long version.
#
# The short version: `cargo install` decides whether to rebuild by reading
# ~/.cargo/.crates.toml, which is cargo's bookkeeping and not the binary.
# Restore the binary from a cache without that file and cargo builds it again
# having been handed the finished article. So the check here is on the ARTIFACT:
# run it, read its version, skip when it matches. That is what lets the workflow
# cache exactly one file, keyed on the pinned version, and actually save the
# ~70 seconds the build costs.
#
# WHY NOT AN ACTION THAT DOWNLOADS A PREBUILT BINARY
#
# There is one, and it is faster. It is also a tenth third-party action in a
# repository that already reasons carefully about what it trusts to produce its
# build, and this one would be trusted to produce the number the project's
# coverage status gates on. Seventy seconds on a cache miss, in a job that gates
# nothing, is a cheap price for the tool coming from crates.io through the same
# `cargo install --locked` as everything else.
#
# Usage:
#   ./scripts/ci-install-llvm-cov.sh              # version from ci.yml
#   LLVM_COV_VERSION=0.8.7 ./scripts/ci-install-llvm-cov.sh

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SELF_DIR/.." || exit 1

# ci.yml is the pin's only home; the workflow exports LLVM_COV_VERSION into the
# step's environment, and a developer running this by hand gets the same value
# read out of the same file.
if [ -z "${LLVM_COV_VERSION:-}" ]; then
  # shellcheck source=ci-versions.sh
  source "$SELF_DIR/ci-versions.sh"
  LLVM_COV_VERSION="$CI_LLVM_COV_VERSION"
fi

installed=""
if command -v cargo-llvm-cov >/dev/null 2>&1; then
  installed="$(cargo llvm-cov --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi

if [ "$installed" = "$LLVM_COV_VERSION" ]; then
  echo "cargo-llvm-cov ${LLVM_COV_VERSION} already installed; skipping the build."
  exit 0
fi

if [ -n "$installed" ]; then
  echo "cargo-llvm-cov ${installed} is installed but ${LLVM_COV_VERSION} is pinned; rebuilding."
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "::error::cargo is not on PATH; cannot install cargo-llvm-cov. Run ./scripts/setup.sh (or see https://rustup.rs)." >&2
  exit 1
fi

cargo install --locked "cargo-llvm-cov@${LLVM_COV_VERSION}" || exit 1

# The component that does the actual instrumenting. rustup is how CI installs
# the toolchain, but a distro-packaged Rust has no rustup at all — say what is
# missing rather than letting cargo-llvm-cov fail later with a message about
# llvm-profdata that names neither this component nor how to get it.
if command -v rustup >/dev/null 2>&1; then
  rustup component add llvm-tools-preview || exit 1
else
  echo "::warning::rustup is not on PATH, so the llvm-tools-preview component cannot be installed here. cargo-llvm-cov needs it; install it however this toolchain provides it." >&2
fi
