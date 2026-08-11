#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Line coverage for the Rust crate, as an lcov report Codecov can merge with
# the two Dart ones.
#
# WHY THE PROJECT NEEDED THIS
#
# rust/ is roughly a third of the hand-written code in this repository — the
# spec parser, the codec, the protocol dispatch, the mock simulator — and
# nothing measured a line of it. `cargo test` ran, and that was the whole of
# what anyone knew. The reported project coverage was the Dart half only, so a
# change that moved Rust coverage in either direction moved the number not at
# all, and the one status check the repo gates on could not see it.
#
# The first run answered the question it was built to ask: the hand-written
# crate is at 95.6%, and rust/src/frb_generated.rs — 1917 lines of
# flutter_rust_bridge output — is at 0.0%, because `cargo test` never crosses
# the FFI boundary that file exists to implement. Left in, it drags a 95.6%
# crate to a reported 72.0%. It is ignored in codecov.yml on exactly the
# argument already made there for the Dart half of the same generated pair; see
# that file.
#
# WHY THE PATHS ARE REWRITTEN
#
# cargo-llvm-cov writes ABSOLUTE paths (/home/runner/work/repo/repo/rust/src/…).
# Codecov tries to map those back onto the repository itself and usually
# manages, but "usually" applied to a file-matching heuristic means the day it
# does not, the report silently covers nothing and the number simply drops.
# Stripping the workspace prefix here makes it repo-relative — rust/src/… —
# which is what the Dart reports already are and what codecov.yml's `ignore`
# patterns are written against.
#
# Usage:
#   ./scripts/ci-rust-coverage.sh                      # writes coverage/rust-lcov.info
#   LB_COVERAGE_PATH=/tmp/x.info ./scripts/ci-rust-coverage.sh
#
# Environment:
#   LB_COVERAGE_PATH   Where to write the lcov report.
#   LLVM_COV_VERSION   Pin override; otherwise read from ci.yml.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

COVERAGE_PATH="${LB_COVERAGE_PATH:-$PROJECT_DIR/coverage/rust-lcov.info}"

./scripts/ci-install-llvm-cov.sh || exit 1

mkdir -p "$(dirname "$COVERAGE_PATH")"

# --locked for the same reason the `rust` job's clippy and test steps carry it:
# a lockfile that disagrees with Cargo.toml must be an error rather than
# something cargo quietly resolves around on the runner.
#
# This RUNS the test suite (that is how llvm-cov collects), so a failing test
# fails this script. It does not replace the `rust` job: that one is the gate
# for four expensive native jobs and stays a plain `cargo test`, unentangled
# with a coverage tool.
(cd rust && cargo llvm-cov --all-features --locked --lcov \
  --output-path "$COVERAGE_PATH")
status=$?

if [ "$status" -ne 0 ]; then
  echo "::error::cargo llvm-cov failed (exit ${status}); no Rust coverage was produced." >&2
  exit "$status"
fi

# Absolute -> repo-relative. See the header for why this is not left to
# Codecov's path fixing.
if [ -s "$COVERAGE_PATH" ]; then
  # A trailing slash on the prefix so `SF:/home/x/repo/rust/…` becomes
  # `SF:rust/…` rather than `SF:/rust/…`.
  sed -i.bak "s|^SF:${PROJECT_DIR}/|SF:|" "$COVERAGE_PATH" && rm -f "${COVERAGE_PATH}.bak"
fi

# A green run that produced an empty report uploads nothing, and Codecov then
# compares a report missing every Rust line against a base that had them — a
# coverage cliff with no change behind it. The same guard
# scripts/ci-netdisco-tests.sh carries, for the same reason.
# grep -c prints its count (0 included) even when it exits non-zero, so the
# fallback must not print a second number: `|| echo 0` turned $records into
# "0\n0", the -lt test errored, and the guard passed the empty report through.
records="$(grep -c '^SF:' "$COVERAGE_PATH" 2>/dev/null || true)"
if [ "${records:-0}" -lt 1 ]; then
  echo "::error::${COVERAGE_PATH} lists no source files, so this job would upload an empty report." >&2
  exit 1
fi

# Absolute paths surviving the rewrite means the workspace moved under us, and
# Codecov would attribute the whole report to files it cannot find.
if grep -q '^SF:/' "$COVERAGE_PATH"; then
  echo "::error::${COVERAGE_PATH} still contains absolute paths; Codecov cannot map them onto the repository." >&2
  grep -m3 '^SF:/' "$COVERAGE_PATH" >&2
  exit 1
fi

echo "Rust coverage written to ${COVERAGE_PATH#"$PROJECT_DIR"/} (${records} source files)."
