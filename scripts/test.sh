#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Mirror CI locally — run dart format, flutter analyze, the FRB binding
# freshness check, flutter test, then cargo fmt/clippy/test. Exit non-zero on
# the first failure.

set -euo pipefail

# Read from .github/workflows/ci.yml, the same way scripts/setup.sh and the
# Claude Code session hook do — a different codegen version rewrites the
# generated bindings differently and would report a spurious (or miss a real)
# drift. This used to be a third hardcoded copy of the pin, which meant a bump
# in ci.yml made setup.sh install the new codegen while this script compared
# against the old one, took its "not the pinned version" skip path, and quietly
# stopped running the drift check that CI still enforces — green locally, red in
# CI, which is the exact gap this script exists to close.
SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-versions.sh
source "$SCRIPT_DIR_EARLY/ci-versions.sh"
FRB_VERSION="$CI_FRB_VERSION"

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"
SCRIPT_DIR="$SCRIPT_DIR_EARLY"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[test]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[test]\033[0m %s\n' "$*"; }

# CI regenerates the flutter_rust_bridge bindings and fails if the committed
# ones differ, so a change to rust/src/api/ that was never re-generated is a
# green local run and a red CI run. Do the same check here.
#
# Skipped (with a warning) rather than fatal when the pinned codegen isn't
# installed: it is a large `cargo install` that ./scripts/setup.sh handles, and
# a missing dev tool shouldn't look like a failing test suite.
check_frb_bindings() {
  if ! command -v flutter_rust_bridge_codegen &>/dev/null; then
    warn "SKIPPING FRB binding check: flutter_rust_bridge_codegen not installed."
    warn "  Install it with: cargo install --locked flutter_rust_bridge_codegen@${FRB_VERSION}"
    warn "  (or run ./scripts/setup.sh). CI still runs this check."
    return 0
  fi
  local installed
  installed="$(flutter_rust_bridge_codegen --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ "$installed" != "$FRB_VERSION" ]]; then
    warn "SKIPPING FRB binding check: codegen ${installed:-unknown} != pinned ${FRB_VERSION}."
    warn "  Re-pin with: cargo install --locked --force flutter_rust_bridge_codegen@${FRB_VERSION}"
    return 0
  fi
  flutter_rust_bridge_codegen generate
  # -I exempts exactly one hunk: flutter_rust_bridge's header comment listing
  # the trait methods it declined to bind takes its names from derive
  # expansions, so `#[derive(Eq)]` reads as `assert_receiver_is_total_eq` under
  # rustc 1.94 and `assert_fields_are_eq` under 1.97. Nothing in the bindings
  # changes with it, and CI floats on stable, so without the exemption a rustc
  # release fails this check for a comment. A hunk carrying anything else still
  # fails. Keep in sync with .github/workflows/ci.yml.
  git diff --exit-code \
    -I '^// These function are ignored because they are on traits' \
    lib/src/rust/ rust/src/frb_generated.rs
  # `git diff` is blind to brand-new (untracked) files, so a first-ever
  # generated file would pass the check above.
  local untracked
  untracked="$(git status --porcelain --untracked-files=all lib/src/rust rust/src/frb_generated.rs | grep '^??' || true)"
  if [[ -n "$untracked" ]]; then
    echo "FRB generated files that are not committed:" >&2
    echo "$untracked" >&2
    return 1
  fi
}

cd "$PROJECT_DIR"

# CI runs pub get before format/analyze/test; without it a fresh clone or a
# dependency bump fails here with a confusing "Target of URI doesn't exist".
# Cheap, and it is what this script provisioned itself from a moment ago: if
# ci.yml's env: block has stopped being readable, THIS run is already using the
# stale fallback pins, and so is every other dev environment. CI's gate job runs
# the same command.
log "ci-versions.sh --strict (toolchain pins still readable from ci.yml?)"
./scripts/ci-versions.sh --strict > /dev/null

log "flutter pub get"
flutter pub get

log "dart format (tracked Dart files)"
./scripts/ci-format.sh

log "flutter analyze --fatal-infos"
flutter analyze --fatal-infos

# CI's `analyze` job lints scripts/ too. Skipped with a warning rather than
# fatal when shellcheck is absent, for the same reason the FRB check below is:
# a missing dev tool should not look like a failing test suite. CI still runs
# it, and CI has shellcheck preinstalled.
if command -v shellcheck &>/dev/null; then
  log "shellcheck (scripts/)"
  ./scripts/ci-shellcheck.sh
else
  warn "SKIPPING shellcheck: not installed."
  warn "  Install it with: sudo apt-get install -y shellcheck (or brew install shellcheck)."
  warn "  CI still runs this check."
fi

# Drives scripts/ci-ios-tests.sh through its whole retry loop against stub
# binaries. Needs no Mac and no simulator, which is the point — it is the only
# way that logic gets exercised outside a real iOS CI failure.
log "ci-ios-tests.sh self-test"
./scripts/ci-ios-tests-selftest.sh

# BEFORE the build, not after. `generate` rewrites rust/src/frb_generated.rs,
# which is an input to the crate — running it second leaves the freshly built
# library looking older than its own sources, so the next thing to ask "is this
# up to date?" (test/helpers/host_rust_lib.dart, and cargo itself) answers no
# and rebuilds work that was just done. Generating first also means the library
# below is built from the bindings this run actually checked.
log "flutter_rust_bridge_codegen generate (bindings up to date?)"
check_frb_bindings

log "host Rust library (FFI-backed tests load it by path)"
./scripts/ensure-rust-lib.sh

# --exclude-tags=netdisco mirrors CI: those suites bind ports 5353 and 1900 for
# real multicast, which a machine running avahi-daemon or systemd-resolved
# cannot spare. Run them with ./scripts/ci-netdisco-tests.sh.
#
# No LD_LIBRARY_PATH/DYLD_FALLBACK_LIBRARY_PATH here, and their absence is the
# fix rather than an omission. They used to be set on this command and never
# reached it: the line continuation ran into a comment, so bash read the two
# assignments as a command of their own — setting a pair of shell variables
# nothing exported — and then ran `flutter test` as a separate, unprefixed
# command. The suites passed anyway, which is the tell: test/helpers/
# host_rust_lib.dart opens rust/target/debug/<lib> by relative path precisely
# because the macOS hardened runtime strips DYLD_* from the `dart` binary, so
# neither variable was ever what made this work.
log "flutter test --coverage --exclude-tags=netdisco"
flutter test --coverage --exclude-tags=netdisco

log "cargo fmt --all -- --check"
(cd rust && cargo fmt --all -- --check)

log "cargo clippy --all-targets --all-features -- -D warnings"
(cd rust && cargo clippy --all-targets --all-features -- -D warnings)

log "cargo test --all-features"
(cd rust && cargo test --all-features)

log "All checks passed."
