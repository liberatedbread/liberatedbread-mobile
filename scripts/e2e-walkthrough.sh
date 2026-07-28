#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — scripted screenshot walkthrough on an iOS Simulator.
#
# Boots a simulator, starts the host-side screenshot server, then runs
# integration_test/e2e_walkthrough_test.dart against the real app in mock mode.
# Every step of the walkthrough lands in $OUT_DIR as a PNG.
#
# Usage:
#   ./scripts/e2e-walkthrough.sh                      # booted sim, ./e2e-shots
#   ./scripts/e2e-walkthrough.sh --udid <UDID>
#   ./scripts/e2e-walkthrough.sh --out ~/e2e_jun24

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

UDID=""
OUT_DIR="${PROJECT_DIR}/e2e-shots"
PORT="${E2E_SHOT_PORT:-8099}"

while (( $# > 0 )); do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --out)  OUT_DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;32m[e2e]\033[0m %s\n' "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[e2e] iOS Simulator walkthroughs require macOS." >&2
  exit 1
fi

# ── pick + boot a simulator ──────────────────────────────────────────────────

list_devices() { xcrun simctl list devices available; }
first_udid() { grep -Eo '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1; }

if [[ -z "$UDID" ]]; then
  # Prefer a simulator that is already booted, else the first iPhone available.
  UDID="$(list_devices | grep '(Booted)' | first_udid || true)"
fi
if [[ -z "$UDID" ]]; then
  UDID="$(list_devices | grep -E '^\s+iPhone' | first_udid || true)"
fi
if [[ -z "$UDID" ]]; then
  echo "[e2e] No iOS simulator found." >&2
  exit 1
fi

log "Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# ── screenshot server ────────────────────────────────────────────────────────

mkdir -p "$OUT_DIR"
log "Screenshots -> $OUT_DIR"

E2E_SHOT_DIR="$OUT_DIR" E2E_UDID="$UDID" E2E_SHOT_PORT="$PORT" \
  python3 "$SCRIPT_DIR/e2e_shot_server.py" &
SHOT_PID=$!
trap 'kill "$SHOT_PID" 2>/dev/null || true' EXIT
sleep 1

# ── run the walkthrough ──────────────────────────────────────────────────────

cd "$PROJECT_DIR"
flutter test integration_test/e2e_walkthrough_test.dart \
  -d "$UDID" \
  --dart-define=LIBERATED_BREAD_MOCK=true \
  --dart-define=E2E_SHOT_PORT="$PORT"

log "Done. $(ls -1 "$OUT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ') screenshots."
