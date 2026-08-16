#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — build and run on a connected PHYSICAL Android phone.
#
# Two modes, because "run it on my phone" means two different things:
#
#   --live      (default) `flutter run` on the attached device: the app is
#               TETHERED to this terminal — hot reload on save, logs stream
#               here, and quitting (or unplugging) stops the app. This is the
#               dev-loop mode. Needs the phone plugged in the whole time.
#
#   --sideload  Build an APK, `adb install` it, and launch it STANDALONE: the
#               app runs on its own, survives unplugging and reboots, and this
#               terminal is free. This is the "leave it on my phone and go test
#               near the actual hardware" mode — the one you want for BLE/Wi-Fi
#               field testing away from the desk.
#
#   --copy      Build an APK and `adb push` the FILE to the phone's Download
#               folder — no install. Hand it off to install yourself from a file
#               manager, keep it, or pass it to someone else. (The same APK also
#               stays on this machine under build/app/outputs/flutter-apk/.)
#
# Unlike run-android.sh, this NEVER boots an emulator: it is for a real device,
# and errors if it only finds an emulator (use run-android.sh for that).
#
# Usage:
#   ./scripts/run-android-device.sh                 # live, on the first phone
#   ./scripts/run-android-device.sh --sideload      # install + launch, untethered
#   ./scripts/run-android-device.sh --copy          # push the APK file, no install
#   ./scripts/run-android-device.sh --sideload --release
#                                                   # a release APK, sideloaded
#   ./scripts/run-android-device.sh --mock          # simulated BLE devices
#   ./scripts/run-android-device.sh --device <serial>   # a specific phone
#   ./scripts/run-android-device.sh --list          # list attached devices, exit
#   ./scripts/run-android-device.sh --sideload --no-launch
#                                                   # install only, don't open it
#   ./scripts/run-android-device.sh -- --verbose    # pass extras to flutter (live)
#
# FIRST-TIME DEVICE SETUP (on the phone):
#   1. Settings → About phone → tap "Build number" 7× to unlock Developer options.
#   2. Settings → System → Developer options → enable "USB debugging".
#   3. Plug in over USB and accept the "Allow USB debugging?" prompt.
#   (Wireless: `adb pair <ip:port>` then `adb connect <ip:port>` also works.)

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PACKAGE_ID="ca.pigscanfly.liberatedbread"

log()  { printf '\033[1;32m[android-device]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[android-device]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[android-device]\033[0m %s\n' "$*" >&2; }

# Follow CI's Flutter pin, exactly as the other run scripts do.
# shellcheck source=flutter-ensure-version.sh
source "$SCRIPT_DIR/flutter-ensure-version.sh"

# ── parse args ───────────────────────────────────────────────────────────────

MODE="live"          # live | sideload | copy
RELEASE=false
MOCK=false
LAUNCH=true          # sideload: launch after install
LIST_ONLY=false
DEVICE=""            # explicit serial, else auto-pick a physical device
PASSTHROUGH=()       # extra args to `flutter run` (live mode only)
SEEN_DDASH=false

while [[ $# -gt 0 ]]; do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$1"); shift; continue
  fi
  case "$1" in
    --live)      MODE="live" ;;
    --sideload)  MODE="sideload" ;;
    --copy)      MODE="copy" ;;
    --release)   RELEASE=true ;;
    --mock)      MOCK=true ;;
    --no-launch) LAUNCH=false ;;
    --list)      LIST_ONLY=true ;;
    --device)    DEVICE="${2:-}"; [[ -n "$DEVICE" ]] || { err "--device needs a serial"; exit 2; }; shift ;;
    --device=*)  DEVICE="${1#--device=}" ;;
    --)          SEEN_DDASH=true ;;
    -h|--help)   awk 'NR>=5 && /^#/ {sub(/^# ?/, ""); print; next} NR>=5 {exit}' "$0"; exit 0 ;;
    *)           err "unknown option: $1 (use --help)"; exit 2 ;;
  esac
  shift
done

# ── tool discovery ───────────────────────────────────────────────────────────

if ! command -v flutter &>/dev/null; then
  err "Flutter not found. Run ./scripts/setup.sh first."
  exit 1
fi
flutter_ensure_ci_version

find_adb() {
  if [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
    echo "${ANDROID_HOME}/platform-tools/adb"; return
  fi
  command -v adb &>/dev/null && { echo adb; return; }
  [[ -x "$HOME/Android/Sdk/platform-tools/adb" ]] && { echo "$HOME/Android/Sdk/platform-tools/adb"; return; }
  [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]] && { echo "$HOME/Library/Android/sdk/platform-tools/adb"; return; }
}

ADB="$(find_adb || true)"
if [[ -z "${ADB:-}" ]]; then
  err "adb not found. Install Android platform-tools or run ./scripts/setup.sh."
  exit 1
fi

# ── pick a physical device ───────────────────────────────────────────────────

# One "serial<TAB>state" line per attached device, "device" state only.
adb_devices() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'; }
# An emulator serial is `emulator-NNNN`; anything else is a real phone or a
# network (`ip:port`) connection.
is_emulator() { [[ "$1" == emulator-* ]]; }

if [[ "$LIST_ONLY" == "true" ]]; then
  log "Attached Android devices:"
  found=false
  while read -r serial; do
    [[ -z "$serial" ]] && continue
    found=true
    model="$("$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"
    kind=$(is_emulator "$serial" && echo emulator || echo physical)
    printf '  %-24s %-10s %s\n' "$serial" "$kind" "${model:-?}"
  done < <(adb_devices)
  [[ "$found" == "true" ]] || warn "  (none — plug in a phone with USB debugging on)"
  exit 0
fi

resolve_device() {
  if [[ -n "$DEVICE" ]]; then
    if adb_devices | grep -qx "$DEVICE"; then
      DEVICE_ID="$DEVICE"; return
    fi
    err "device '$DEVICE' is not attached/online. See: $0 --list"
    exit 1
  fi
  # Auto-pick: the first PHYSICAL device. An emulator is explicitly not us.
  local phys
  phys="$(adb_devices | while read -r s; do is_emulator "$s" || echo "$s"; done | head -n1)"
  if [[ -z "$phys" ]]; then
    if adb_devices | grep -q .; then
      err "Only an emulator is attached. This script is for a physical phone —"
      err "use ./scripts/run-android.sh for the emulator, or pass --device <serial>."
    else
      err "No Android device online. Plug in a phone with USB debugging enabled"
      err "(see the header of this script), then: $0 --list"
    fi
    exit 1
  fi
  DEVICE_ID="$phys"
}

resolve_device
MODEL="$("$ADB" -s "$DEVICE_ID" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"
log "Device: $DEVICE_ID (${MODEL:-unknown})"

# ── dart deps ────────────────────────────────────────────────────────────────

cd "$PROJECT_DIR"
if [[ ! -d ".dart_tool" ]]; then
  log "flutter pub get..."
  flutter pub get
fi

DEFINES=()
if [[ "$MOCK" == "true" ]]; then
  log "Mock mode — simulated BLE devices baked in."
  DEFINES+=("--dart-define=LIBERATED_BREAD_MOCK=true")
fi

# ── run ──────────────────────────────────────────────────────────────────────

if [[ "$MODE" == "live" ]]; then
  # Tethered dev loop: flutter owns the app, hot reload on save.
  ARGS=("run" "-d" "$DEVICE_ID")
  [[ "$RELEASE" == "true" ]] && ARGS+=("--release")
  ARGS+=("${DEFINES[@]}")
  (( ${#PASSTHROUGH[@]} > 0 )) && ARGS+=("${PASSTHROUGH[@]}")
  log "Live (hot reload). Press r to reload, q to quit."
  log "flutter ${ARGS[*]}"
  exec flutter "${ARGS[@]}"
fi

# sideload / copy: both need an APK, so build once here.
if (( ${#PASSTHROUGH[@]} > 0 )); then
  warn "Ignoring passthrough args ${PASSTHROUGH[*]} — they only apply to --live."
fi

BUILD_TYPE=$([[ "$RELEASE" == "true" ]] && echo release || echo debug)
APK="build/app/outputs/flutter-apk/app-${BUILD_TYPE}.apk"

log "Building the ${BUILD_TYPE} APK..."
BUILD_ARGS=("build" "apk" "--${BUILD_TYPE}")
BUILD_ARGS+=("${DEFINES[@]}")
flutter "${BUILD_ARGS[@]}"

if [[ ! -f "$APK" ]]; then
  err "Expected APK not found at $APK after the build."
  exit 1
fi

if [[ "$MODE" == "copy" ]]; then
  # Push the FILE, do not install. A timestamped name so repeated copies don't
  # clobber each other on the phone, and the app id + build type are legible.
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo build)"
  dest="/sdcard/Download/liberated-bread-${BUILD_TYPE}-${stamp}.apk"
  log "Copying $APK to the phone..."
  "$ADB" -s "$DEVICE_ID" push "$APK" "$dest"
  log "Copied to $dest on $DEVICE_ID."
  log "Install it on the phone: open Files → Download → that .apk (allow"
  log "\"install unknown apps\" for your file manager the first time)."
  log "The same APK is on this machine at: $APK"
  exit 0
fi

# sideload: install → (optionally) launch, standalone.
log "Installing $APK on $DEVICE_ID (reinstall, keep data)..."
# -r reinstall keeping data; -d allow a version-code downgrade during dev.
"$ADB" -s "$DEVICE_ID" install -r -d "$APK"

if [[ "$LAUNCH" == "true" ]]; then
  log "Launching $PACKAGE_ID..."
  # monkey with the LAUNCHER category resolves and starts the main activity
  # without hardcoding its name.
  "$ADB" -s "$DEVICE_ID" shell monkey -p "$PACKAGE_ID" \
    -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
    || warn "Installed, but could not auto-launch — open it from the app drawer."
  log "Installed and launched. It runs on its own now; you can unplug."
else
  log "Installed (not launched). Open it from the app drawer when ready."
fi
log "Logs, if you want them: $ADB -s $DEVICE_ID logcat --pid=\$($ADB -s $DEVICE_ID shell pidof $PACKAGE_ID)"
