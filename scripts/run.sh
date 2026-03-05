#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# OpenGreenIoT Mobile — build and run
# Usage:
#   ./scripts/run.sh           # Run on connected device or emulator
#   ./scripts/run.sh --mock    # Run with mock BLE devices (no hardware needed)

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[run]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[run]\033[0m %s\n' "$*" >&2; }

# ── parse args ───────────────────────────────────────────────────────────────

MOCK=false
EXTRA_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --mock) MOCK=true ;;
    *)      EXTRA_ARGS+=("$arg") ;;
  esac
done

# ── check flutter ────────────────────────────────────────────────────────────

if ! command -v flutter &>/dev/null; then
  err "Flutter not found. Run ./scripts/setup.sh first."
  exit 1
fi

# ── ensure dependencies ──────────────────────────────────────────────────────

cd "$PROJECT_DIR"

if [[ ! -d ".dart_tool" ]]; then
  log "Running flutter pub get..."
  flutter pub get
fi

# ── find or launch a device ──────────────────────────────────────────────────

ensure_device() {
  # Check for connected devices (physical or already-running emulator)
  local devices
  devices="$(flutter devices 2>/dev/null | grep -c '•' || true)"

  if [[ "$devices" -gt 0 ]]; then
    log "Found connected device."
    return
  fi

  log "No connected device found. Looking for emulator..."

  # Try to find the emulator binary
  local emulator=""
  if command -v emulator &>/dev/null; then
    emulator="emulator"
  elif [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/emulator/emulator" ]]; then
    emulator="${ANDROID_HOME}/emulator/emulator"
  elif [[ -x "$HOME/Android/Sdk/emulator/emulator" ]]; then
    emulator="$HOME/Android/Sdk/emulator/emulator"
  fi

  if [[ -z "$emulator" ]]; then
    err "No device connected and emulator not found."
    err "Connect a device via USB/WiFi or run ./scripts/setup.sh to create an emulator."
    exit 1
  fi

  # Check if our AVD exists
  if ! "$emulator" -list-avds 2>/dev/null | grep -q "opengreeniot_test"; then
    err "AVD 'opengreeniot_test' not found. Run ./scripts/setup.sh to create it."
    exit 1
  fi

  log "Launching emulator opengreeniot_test..."
  "$emulator" -avd opengreeniot_test -no-snapshot-load &
  local emu_pid=$!

  # Wait for the emulator to boot
  log "Waiting for emulator to boot..."
  local adb_cmd="adb"
  if [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    adb_cmd="${ANDROID_HOME}/platform-tools/adb"
  fi

  "$adb_cmd" wait-for-device 2>/dev/null
  # Wait for boot animation to finish
  local timeout=120
  local elapsed=0
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local booted
    booted="$("$adb_cmd" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$booted" == "1" ]]; then
      log "Emulator booted."
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  warn "Emulator may not have fully booted (timed out after ${timeout}s). Attempting to run anyway."
}

# ── build flutter args ───────────────────────────────────────────────────────

FLUTTER_ARGS=("run")

if [[ "$MOCK" == "true" ]]; then
  log "Mock mode enabled — using simulated BLE devices."
  FLUTTER_ARGS+=("--dart-define=OPENGREENIOT_MOCK=true")
fi

FLUTTER_ARGS+=("${EXTRA_ARGS[@]}")

# ── go ───────────────────────────────────────────────────────────────────────

ensure_device
log "Running: flutter ${FLUTTER_ARGS[*]}"
exec flutter "${FLUTTER_ARGS[@]}"
