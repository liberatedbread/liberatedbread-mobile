#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — build and launch on Android emulator
#
# Boots the liberated_bread_test AVD (or reuses any connected Android device),
# waits for it, then builds and runs the app via `flutter run`.
#
# Usage:
#   ./scripts/run-android.sh                  # Run on Android emulator/device
#   ./scripts/run-android.sh --mock           # Run with simulated BLE devices
#   ./scripts/run-android.sh --release        # Release build
#   ./scripts/run-android.sh --mock -- --verbose
#                                             # Pass extra args to `flutter run`

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

AVD_NAME="liberated_bread_test"

log()  { printf '\033[1;32m[android]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[android]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[android]\033[0m %s\n' "$*" >&2; }

# Auto-upgrades the repo-managed SDK at ~/.flutter-sdk to CI's pinned Flutter.
# shellcheck source=flutter-ensure-version.sh
source "$SCRIPT_DIR/flutter-ensure-version.sh"

# ── parse args ───────────────────────────────────────────────────────────────

MOCK=false
RELEASE=false
PASSTHROUGH=()
SEEN_DDASH=false

for arg in "$@"; do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$arg")
    continue
  fi
  case "$arg" in
    --mock)    MOCK=true ;;
    --release) RELEASE=true ;;
    --)        SEEN_DDASH=true ;;
    *)         PASSTHROUGH+=("$arg") ;;
  esac
done

# ── tool discovery ───────────────────────────────────────────────────────────

if ! command -v flutter &>/dev/null; then
  err "Flutter not found. Run ./scripts/setup.sh first."
  exit 1
fi

# Follow CI's Flutter pin: upgrade ~/.flutter-sdk in place when it is stale, so
# a version bump in ci.yml doesn't turn into a confusing `flutter pub get`
# failure here. A Flutter installed elsewhere is left alone. (LB_FLUTTER_AUTO_UPGRADE=0 skips.)
flutter_ensure_ci_version

find_emulator() {
  if command -v emulator &>/dev/null; then
    echo "emulator"; return
  fi
  if [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/emulator/emulator" ]]; then
    echo "${ANDROID_HOME}/emulator/emulator"; return
  fi
  if [[ -x "$HOME/Android/Sdk/emulator/emulator" ]]; then
    echo "$HOME/Android/Sdk/emulator/emulator"; return
  fi
  if [[ -x "$HOME/Library/Android/sdk/emulator/emulator" ]]; then
    echo "$HOME/Library/Android/sdk/emulator/emulator"; return
  fi
}

find_adb() {
  if [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    echo "${ANDROID_HOME}/platform-tools/adb"; return
  fi
  if command -v adb &>/dev/null; then
    echo "adb"; return
  fi
  if [[ -x "$HOME/Android/Sdk/platform-tools/adb" ]]; then
    echo "$HOME/Android/Sdk/platform-tools/adb"; return
  fi
  if [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
    echo "$HOME/Library/Android/sdk/platform-tools/adb"; return
  fi
}

ADB="$(find_adb || true)"
if [[ -z "${ADB:-}" ]]; then
  err "adb not found. Install Android platform-tools or run ./scripts/setup.sh."
  exit 1
fi

# ── ensure dart deps ─────────────────────────────────────────────────────────

cd "$PROJECT_DIR"
if [[ ! -d ".dart_tool" ]]; then
  log "Running flutter pub get..."
  flutter pub get
fi

# ── ensure an Android device is online ───────────────────────────────────────

list_online_devices() {
  # Outputs one device serial per line (only "device" state, skips "offline").
  "$ADB" devices 2>/dev/null \
    | awk 'NR>1 && $2=="device" {print $1}'
}

ensure_emulator() {
  local online
  online="$(list_online_devices | head -n1)"
  if [[ -n "$online" ]]; then
    log "Android device already online: $online"
    DEVICE_ID="$online"
    return
  fi

  log "No Android device online. Looking for emulator..."
  local emulator
  emulator="$(find_emulator || true)"
  if [[ -z "${emulator:-}" ]]; then
    err "Android emulator binary not found."
    err "Install the Android SDK or run ./scripts/setup.sh to create one."
    exit 1
  fi

  if ! "$emulator" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    err "AVD '$AVD_NAME' not found. Run ./scripts/setup.sh to create it."
    exit 1
  fi

  log "Launching emulator $AVD_NAME..."
  "$emulator" -avd "$AVD_NAME" -no-snapshot-load >/dev/null 2>&1 &

  log "Waiting for emulator to register with adb..."
  "$ADB" wait-for-device

  log "Waiting for boot to complete..."
  local timeout=180
  local elapsed=0
  while (( elapsed < timeout )); do
    local booted
    booted="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$booted" == "1" ]]; then
      log "Emulator booted."
      DEVICE_ID="$(list_online_devices | head -n1)"
      return
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  warn "Emulator boot timed out after ${timeout}s; trying flutter run anyway."
  DEVICE_ID="$(list_online_devices | head -n1)"
  if [[ -z "$DEVICE_ID" ]]; then
    err "No device serial visible to adb. Aborting."
    exit 1
  fi
}

ensure_emulator

# ── build flutter args ───────────────────────────────────────────────────────

FLUTTER_ARGS=("run" "-d" "$DEVICE_ID")

if [[ "$RELEASE" == "true" ]]; then
  FLUTTER_ARGS+=("--release")
fi

if [[ "$MOCK" == "true" ]]; then
  log "Mock mode enabled — using simulated BLE devices."
  FLUTTER_ARGS+=("--dart-define=LIBERATED_BREAD_MOCK=true")
fi

if (( ${#PASSTHROUGH[@]} > 0 )); then
  FLUTTER_ARGS+=("${PASSTHROUGH[@]}")
fi

log "Running: flutter ${FLUTTER_ARGS[*]}"
exec flutter "${FLUTTER_ARGS[@]}"
