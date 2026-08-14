#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# SessionStart hook for Claude Code on the web. Installs the Python toolchain
# this repo's own checks need, so a web session can run them immediately:
#
#   ruff check .                       # lint
#   pytest -q                          # tests
#   python scripts/validate_specs.py   # spec schema validation
#   python scripts/build_index.py --check
#   mkdocs build --strict              # docs build
#
# Deps go in a project-local virtualenv rather than the system interpreter:
# recent Debian/Ubuntu images mark the system Python "externally managed"
# (PEP 668), so a bare `pip install` there fails. The venv's bin/ is prepended
# to PATH for the session via CLAUDE_ENV_FILE, so `ruff`, `pytest` and `mkdocs`
# resolve without activation.
#
# Idempotent and safe to re-run. Local machines set up their own env (see
# README.md — Development), so this only runs in the remote (web) environment.
set -euo pipefail

# Only provision in the remote (web) environment.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
VENV_DIR="${LB_SPECS_VENV:-$HOME/.lb-specs-venv}"

log() { printf '[session-start] %s\n' "$*"; }

# Keep verbose pip output out of the session context; surface it only on
# failure.
WORK_LOG="$(mktemp)"
on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[session-start] FAILED (exit $rc). Last output:"
    tail -n 40 "$WORK_LOG"
  fi
  rm -f "$WORK_LOG"
  exit "$rc"
}
trap on_exit EXIT

PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
  echo "[session-start] no python3 on PATH; cannot provision." >&2
  exit 1
fi

if [ ! -x "$VENV_DIR/bin/python" ]; then
  log "Creating virtualenv at $VENV_DIR..."
  "$PY" -m venv "$VENV_DIR" >>"$WORK_LOG" 2>&1
fi

log "Installing Python deps (requirements.txt + requirements-dev.txt)..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip >>"$WORK_LOG" 2>&1
"$VENV_DIR/bin/python" -m pip install \
  -r "$PROJECT_DIR/requirements.txt" \
  -r "$PROJECT_DIR/requirements-dev.txt" >>"$WORK_LOG" 2>&1

# Prepend the venv so ruff/pytest/mkdocs resolve for the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$VENV_DIR/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

export PATH="$VENV_DIR/bin:$PATH"
log "Ready. ruff check . / pytest -q / python scripts/validate_specs.py / mkdocs build --strict"
