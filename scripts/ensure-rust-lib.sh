#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Build the HOST-target Rust cdylib the `flutter test` suites load, and prove
# the artifact is actually there afterwards.
#
# WHY THIS IS A SCRIPT AND NOT `cd rust && cargo build`
#
# Four places need this exact thing — scripts/test.sh, the Claude Code session
# hook, CI's unit-tests job, and test/helpers/host_rust_lib.dart when it finds
# no build to load — and each one had its own spelling of it. That is fine right
# up until the answer to "where does the artifact land?" has to change, at
# which point three of the four are wrong and the fourth is the one you did not
# think of.
#
# More to the point, `cargo build` exiting 0 does NOT mean the cdylib exists.
# rust/Cargo.toml declares `crate-type = ["lib", "staticlib", "cdylib"]`;
# dropping the cdylib entry (or renaming the package, which is what determines
# the filename cargokit's pod/gradle build looks for) still builds green and
# still produces a `lib` rlib. What it stops producing is the one file every
# FFI-backed test opens by path — and those tests SELF-SKIP when it is absent,
# so the whole thing reads as a green run with a quietly smaller suite. That is
# the same failure mode scripts/verify_apk.sh and verify_linux_bundle.sh exist
# to catch on the packaged targets; this is its host-side counterpart.
#
# Usage:
#   ./scripts/ensure-rust-lib.sh                 # build (debug) and verify
#   ./scripts/ensure-rust-lib.sh --release       # build the release profile
#   ./scripts/ensure-rust-lib.sh --print-path    # print where it lands, build nothing
#   ./scripts/ensure-rust-lib.sh --quiet         # only speak up on failure
#
# Exit codes:
#   0  the library is built and present
#   1  cargo failed, or it succeeded and the artifact is missing
#   2  no cargo on PATH (callers decide: fatal for CI, a skip for a laptop)
#
# Environment:
#   CARGO_BUILD_ARGS   Extra arguments appended to `cargo build`, word-split.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

profile="debug"
print_path_only=0
quiet=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)    profile="release" ;;
    --debug)      profile="debug" ;;
    --print-path) print_path_only=1 ;;
    --quiet|-q)   quiet=1 ;;
    -h|--help)    sed -n '5,40p' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
    *)
      echo "ensure-rust-lib: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
  shift
done

say() { [ "$quiet" -eq 1 ] || printf '[rust-lib] %s\n' "$*"; }

# The filename cargo produces for `[lib] name = "liberated_bread_core"` on this
# platform. Kept in step with test/helpers/host_rust_lib.dart, which opens the
# same file by path.
case "$(uname -s)" in
  Darwin)               lib_file="libliberated_bread_core.dylib" ;;
  CYGWIN*|MINGW*|MSYS*) lib_file="liberated_bread_core.dll" ;;
  *)                    lib_file="libliberated_bread_core.so" ;;
esac

lib_path="$PROJECT_DIR/rust/target/$profile/$lib_file"

if [ "$print_path_only" -eq 1 ]; then
  printf '%s\n' "$lib_path"
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "[rust-lib] cargo is not on PATH; cannot build the host Rust library." >&2
  echo "[rust-lib]   Install it with ./scripts/setup.sh (or https://rustup.rs)." >&2
  echo "[rust-lib]   The FFI-backed flutter tests will skip themselves without it." >&2
  exit 2
fi

# Incremental: a no-op run of this is under a tenth of a second, which is what
# makes it safe to call from every test entry point rather than asking the
# developer to remember. Cargo is the authority on whether anything needs
# rebuilding — deliberately no mtime guessing here.
say "cargo build (${profile} profile, host target)"
build_args=(build)
[ "$profile" = "release" ] && build_args+=(--release)
[ "$quiet" -eq 1 ] && build_args+=(--quiet)
# shellcheck disable=SC2206  # word splitting is how extra args are passed
[ -n "${CARGO_BUILD_ARGS:-}" ] && build_args+=(${CARGO_BUILD_ARGS})

if ! (cd "$PROJECT_DIR/rust" && cargo "${build_args[@]}"); then
  echo "::error::cargo build failed; the host Rust library was not produced." >&2
  exit 1
fi

if [ ! -f "$lib_path" ]; then
  echo "::error::cargo build succeeded but ${lib_path#"$PROJECT_DIR"/} is missing. rust/Cargo.toml must keep \`cdylib\` in its crate-type and the package name must stay liberated_bread_core — every FFI-backed test opens that exact file by path, and they SKIP rather than fail when it is absent, so this would otherwise show up as a green run with a smaller suite." >&2
  exit 1
fi

say "${lib_path#"$PROJECT_DIR"/} is up to date."
