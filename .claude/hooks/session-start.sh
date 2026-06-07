#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# SessionStart hook for Claude Code on the web. Provisions the *host* toolchain
# needed to run the test suite and linters (scripts/test.sh): the pinned Flutter
# SDK, Dart dependencies, and the host-target Rust library that the FFI-backed
# tests load. It deliberately skips the Android SDK/NDK/emulator and iOS bits —
# those are only needed to build mobile artifacts; run scripts/setup.sh for a
# full mobile build environment. Idempotent and safe to re-run.
set -euo pipefail

# Only provision in the remote (web) environment; local machines use setup.sh.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

FLUTTER_VERSION="3.24.5"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

log() { printf '[session-start] %s\n' "$*"; }

# Keep verbose build output out of the session context; surface it only on
# failure.
WORK_LOG="$(mktemp)"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "[session-start] FAILED (exit $rc). Last output:"; tail -n 40 "$WORK_LOG"; fi' EXIT

# 1. Flutter SDK, pinned to match CI.
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  log "Installing Flutter ${FLUTTER_VERSION}..."
  archive="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}"
  tmp="$(mktemp -d)"
  curl -fSL -o "$tmp/$archive" "$url" >>"$WORK_LOG" 2>&1
  mkdir -p "$(dirname "$FLUTTER_HOME")"
  tar xf "$tmp/$archive" -C "$tmp" >>"$WORK_LOG" 2>&1
  rm -rf "$FLUTTER_HOME"
  mv "$tmp/flutter" "$FLUTTER_HOME"
  rm -rf "$tmp"
else
  log "Flutter already installed at $FLUTTER_HOME"
fi

export PATH="$FLUTTER_HOME/bin:$HOME/.cargo/bin:$PATH"

# Flutter shells out to git inside its SDK; mark it safe when ownership differs
# (containers often extract the SDK as a different user).
if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$FLUTTER_HOME"; then
  git config --global --add safe.directory "$FLUTTER_HOME" || true
fi

# 2. Dart dependencies.
log "flutter pub get..."
(cd "$PROJECT_DIR" && flutter pub get) >>"$WORK_LOG" 2>&1

# 3. Host Rust library so the FFI-backed flutter tests can load it. Skipped
#    gracefully if no Rust toolchain is present (those tests self-skip).
if command -v cargo >/dev/null 2>&1; then
  log "cargo build (host Rust library)..."
  (cd "$PROJECT_DIR/rust" && cargo build) >>"$WORK_LOG" 2>&1
else
  log "cargo not found; skipping host Rust build (FFI tests will self-skip)."
fi

# 4. Persist environment for the session: tools on PATH, and the host Rust lib
#    discoverable by `flutter test` (mirrors scripts/test.sh).
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$FLUTTER_HOME/bin:\$HOME/.cargo/bin:\$PATH\""
    echo "export LD_LIBRARY_PATH=\"$PROJECT_DIR/rust/target/debug:\${LD_LIBRARY_PATH:-}\""
  } >> "$CLAUDE_ENV_FILE"
fi

log "Ready. Run ./scripts/test.sh to mirror CI (Flutter + Rust host jobs)."
