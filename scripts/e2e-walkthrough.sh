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
#   ./scripts/e2e-walkthrough.sh --help

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

UDID=""
OUT_DIR="${PROJECT_DIR}/e2e-shots"
PORT="${E2E_SHOT_PORT:-8099}"

log() { printf '\033[1;32m[e2e]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[e2e]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./scripts/e2e-walkthrough.sh [options]

Boots an iOS Simulator, starts the host-side screenshot server, and runs
integration_test/e2e_walkthrough_test.dart against the app in mock mode.

Options:
  --udid <UDID>  Simulator to drive (default: a booted one, else the first iPhone)
  --out <DIR>    Directory for the PNGs (default: <repo>/e2e-shots)
  --port <PORT>  Port for the screenshot server (default: $E2E_SHOT_PORT or 8099)
  -h, --help     Show this help and exit
EOF
}

# Every valued flag checks its arity first: under `set -u` a trailing `--udid`
# would otherwise die on "$2: unbound variable" instead of saying what's wrong.
while (( $# > 0 )); do
  case "$1" in
    --udid)
      [[ $# -lt 2 ]] && { err "--udid requires a simulator UDID."; exit 2; }
      UDID="$2"; shift 2 ;;
    --out)
      [[ $# -lt 2 ]] && { err "--out requires a directory."; exit 2; }
      OUT_DIR="$2"; shift 2 ;;
    --port)
      [[ $# -lt 2 ]] && { err "--port requires a port number."; exit 2; }
      PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

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

# Wait for the server to actually answer instead of sleeping and hoping. The
# walkthrough tolerates a missing shot server by design (it skips the images
# and still asserts), so a server that died on startup — port already in use,
# no python3 — would sail through as a green run that captured nothing.
# /pack/pack.json is served by the same handler as /shot but has no side
# effects, so polling it doesn't burn a screenshot.
log "Waiting for the screenshot server on 127.0.0.1:$PORT ..."
SHOT_READY=false
for ((attempt = 0; attempt < 50; attempt++)); do
  if ! kill -0 "$SHOT_PID" 2>/dev/null; then
    err "Screenshot server exited during startup (is port $PORT already in use?)."
    exit 1
  fi
  # -s (not -sS): the first attempt or two are expected to fail while python
  # binds the socket, and that is not worth printing.
  if curl -fs --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/pack/pack.json"; then
    SHOT_READY=true
    break
  fi
  sleep 0.1
done
if [[ "$SHOT_READY" != "true" ]]; then
  err "Screenshot server never became ready on 127.0.0.1:$PORT."
  exit 1
fi
log "Screenshot server ready (pid $SHOT_PID)."

# ── run the walkthrough ──────────────────────────────────────────────────────

# Baseline stamp: only PNGs newer than this count as this run's output.
# Without it, stale screenshots from an earlier walkthrough make a run that
# captured nothing (server died after the readiness probe, every capture
# skipped) look successful.
RUN_STAMP="$(mktemp)"
trap 'kill "$SHOT_PID" 2>/dev/null || true; rm -f "$RUN_STAMP"' EXIT

cd "$PROJECT_DIR"
flutter test integration_test/e2e_walkthrough_test.dart \
  -d "$UDID" \
  --dart-define=LIBERATED_BREAD_MOCK=true \
  --dart-define=E2E_SHOT_PORT="$PORT"

# `flutter test` passing is not enough: the test skips screenshots it couldn't
# get, so a run that captured nothing still exits 0. The images are the point
# of this script, so no FRESH images is a failure — pre-existing PNGs from an
# earlier run don't count.
SHOT_COUNT="$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.png' -newer "$RUN_STAMP" | wc -l | tr -d ' ')"
if (( SHOT_COUNT == 0 )); then
  STALE_COUNT="$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
  err "The walkthrough passed but captured no NEW screenshots in $OUT_DIR"
  err "($STALE_COUNT stale one(s) from an earlier run are present)."
  err "Check the [shot] lines above for why every capture was skipped."
  exit 1
fi

log "Done. $SHOT_COUNT screenshots in $OUT_DIR."
