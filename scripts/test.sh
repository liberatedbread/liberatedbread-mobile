#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Mirror CI locally — run dart format, flutter analyze, the FRB binding
# freshness check, flutter test, then cargo fmt/clippy/test. Exit non-zero on
# the first failure.

set -euo pipefail

# Keep in sync with the pin in .github/workflows/ci.yml and scripts/setup.sh —
# a different codegen version rewrites the generated bindings differently and
# would report a spurious (or miss a real) drift.
FRB_VERSION="2.9.0"

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  # `git diff --exit-code` catches edits to tracked generated files but is
  # blind to brand-new (untracked) ones, so also fail on ANY pending change
  # under the generated paths. Keep in sync with .github/workflows/ci.yml.
  git diff --exit-code lib/src/rust/ rust/src/frb_generated.rs
  local drift
  drift="$(git status --porcelain --untracked-files=all lib/src/rust rust/src/frb_generated.rs)"
  if [[ -n "$drift" ]]; then
    echo "FRB generated output is stale (modified or untracked files):" >&2
    echo "$drift" >&2
    return 1
  fi
}

cd "$PROJECT_DIR"

# CI runs pub get before format/analyze/test; without it a fresh clone or a
# dependency bump fails here with a confusing "Target of URI doesn't exist".
log "flutter pub get"
flutter pub get

log "dart format --set-exit-if-changed ."
dart format --set-exit-if-changed .

log "flutter analyze --fatal-infos"
flutter analyze --fatal-infos

log "cargo build (host Rust lib for FRB)"
(cd rust && cargo build)

log "flutter_rust_bridge_codegen generate (bindings up to date?)"
check_frb_bindings

log "flutter test --coverage"
LD_LIBRARY_PATH="$PROJECT_DIR/rust/target/debug:${LD_LIBRARY_PATH:-}" \
DYLD_FALLBACK_LIBRARY_PATH="$PROJECT_DIR/rust/target/debug:${DYLD_FALLBACK_LIBRARY_PATH:-}" \
flutter test --coverage

log "cargo fmt --all -- --check"
(cd rust && cargo fmt --all -- --check)

log "cargo clippy --all-targets --all-features -- -D warnings"
(cd rust && cargo clippy --all-targets --all-features -- -D warnings)

log "cargo test --all-features"
(cd rust && cargo test --all-features)

log "All checks passed."
