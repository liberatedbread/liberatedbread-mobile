#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Mirror CI locally — run dart format, flutter analyze, flutter test,
# then cargo fmt/clippy/test. Exit non-zero on the first failure.

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '\033[1;32m[test]\033[0m %s\n' "$*"; }

cd "$PROJECT_DIR"

log "dart format --set-exit-if-changed ."
dart format --set-exit-if-changed .

log "flutter analyze --fatal-infos"
flutter analyze --fatal-infos

log "flutter test --coverage"
flutter test --coverage

log "cargo fmt --all -- --check"
(cd rust && cargo fmt --all -- --check)

log "cargo clippy --all-targets -- -D warnings"
(cd rust && cargo clippy --all-targets -- -D warnings)

log "cargo test --all-features"
(cd rust && cargo test --all-features)

log "All checks passed."
