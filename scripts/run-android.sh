#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — build, run, install or copy on Android.
#
# WHERE it runs (target), pick one — default is "auto":
#   (default)     Use a connected device if one is online, otherwise boot the
#                 liberated_bread_test emulator. The everyday default.
#   --attached    A physical phone only. Never boots the emulator; errors if the
#                 only thing attached is one. This is "run on my actual phone".
#   --emulator    The liberated_bread_test emulator, booting it if needed, even
#                 when a phone is also plugged in.
#   --device <s>  A specific device serial (see --list).
#
# WHAT it does (action), pick one — default is "live":
#   (default)     `flutter run` on the target: TETHERED to this terminal — hot
#                 reload on save, logs stream here, quitting stops the app.
#   --sideload    Build an APK, `adb install` it, and launch it STANDALONE: it
#                 runs on its own, survives unplugging, and frees this terminal.
#                 The mode for BLE/Wi-Fi field testing away from the desk.
#   --copy        Build an APK and `adb push` the FILE to the phone's Download
#                 folder — no install. Install it yourself later, or hand it off.
#
# Modifiers:
#   --release     Release build (no hot reload).
#   --mock        Simulated BLE devices (--dart-define=LIBERATED_BREAD_MOCK=true).
#   --no-launch   With --sideload: install but do not open the app.
#   --list        List attached devices and exit.
#   -- <args...>  Passed through to `flutter run` (live action only).
#
# Examples:
#   ./scripts/run-android.sh                     # auto target, live (dev loop)
#   ./scripts/run-android.sh --attached          # live on my physical phone
#   ./scripts/run-android.sh --emulator --mock   # emulator, simulated devices
#   ./scripts/run-android.sh --attached --sideload   # install standalone on the phone
#   ./scripts/run-android.sh --attached --copy --release   # push a release APK to the phone
#   ./scripts/run-android.sh --list
#
# FIRST-TIME PHONE SETUP (physical device):
#   1. Settings → About phone → tap "Build number" 7× to unlock Developer options.
#   2. Developer options → enable "USB debugging".
#   3. Plug in over USB and accept the "Allow USB debugging?" prompt.

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

AVD_NAME="liberated_bread_test"
PACKAGE_ID="ca.pigscanfly.liberatedbread"

log()  { printf '\033[1;32m[android]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[android]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[android]\033[0m %s\n' "$*" >&2; }

# Auto-upgrades the repo-managed SDK at ~/.flutter-sdk to CI's pinned Flutter.
# shellcheck source=flutter-ensure-version.sh
source "$SCRIPT_DIR/flutter-ensure-version.sh"

# ── parse args ───────────────────────────────────────────────────────────────

TARGET="auto"        # auto | attached | emulator (a --device overrides all)
ACTION="live"        # live | sideload | copy
RELEASE=false
MOCK=false
LAUNCH=true          # sideload: launch after install
LIST_ONLY=false
DEVICE=""            # explicit serial
PASSTHROUGH=()       # extra args to `flutter run`
SEEN_DDASH=false

while [[ $# -gt 0 ]]; do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$1"); shift; continue
  fi
  case "$1" in
    --attached|--physical) TARGET="attached" ;;
    --emulator)            TARGET="emulator" ;;
    --device)              DEVICE="${2:-}"; [[ -n "$DEVICE" ]] || { err "--device needs a serial"; exit 2; }; shift ;;
    --device=*)            DEVICE="${1#--device=}" ;;
    --sideload)            ACTION="sideload" ;;
    --copy)                ACTION="copy" ;;
    --release)             RELEASE=true ;;
    --mock)                MOCK=true ;;
    --no-launch)           LAUNCH=false ;;
    --list)                LIST_ONLY=true ;;
    --)                    SEEN_DDASH=true ;;
    -h|--help)             awk 'NR>=5 && /^#/ {sub(/^# ?/, ""); print; next} NR>=5 {exit}' "$0"; exit 0 ;;
    *)                     err "unknown option: $1 (use --help)"; exit 2 ;;
  esac
  shift
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
  command -v emulator &>/dev/null && { echo emulator; return; }
  [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/emulator/emulator" ]] && { echo "${ANDROID_HOME}/emulator/emulator"; return; }
  [[ -x "$HOME/Android/Sdk/emulator/emulator" ]] && { echo "$HOME/Android/Sdk/emulator/emulator"; return; }
  [[ -x "$HOME/Library/Android/sdk/emulator/emulator" ]] && { echo "$HOME/Library/Android/sdk/emulator/emulator"; return; }
}

find_adb() {
  [[ -n "${ANDROID_HOME:-}" ]] && [[ -x "${ANDROID_HOME}/platform-tools/adb" ]] && { echo "${ANDROID_HOME}/platform-tools/adb"; return; }
  command -v adb &>/dev/null && { echo adb; return; }
  [[ -x "$HOME/Android/Sdk/platform-tools/adb" ]] && { echo "$HOME/Android/Sdk/platform-tools/adb"; return; }
  [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]] && { echo "$HOME/Library/Android/sdk/platform-tools/adb"; return; }
}

ADB="$(find_adb || true)"
if [[ -z "${ADB:-}" ]]; then
  err "adb not found. Install Android platform-tools or run ./scripts/setup.sh."
  exit 1
fi

# ── device discovery ─────────────────────────────────────────────────────────

# One serial per online ("device" state) device.
list_online_devices() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'; }
# `emulator-NNNN` is an emulator; anything else is a real phone or a network
# (`ip:port`) connection.
is_emulator() { [[ "$1" == emulator-* ]]; }
first_physical() { list_online_devices | while read -r s; do is_emulator "$s" || echo "$s"; done | head -n1; }
first_emulator() { list_online_devices | while read -r s; do is_emulator "$s" && echo "$s"; done | head -n1; }

if [[ "$LIST_ONLY" == "true" ]]; then
  log "Attached Android devices:"
  found=false
  while read -r serial; do
    [[ -z "$serial" ]] && continue
    found=true
    model="$("$ADB" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r' || true)"
    kind=$(is_emulator "$serial" && echo emulator || echo physical)
    printf '  %-24s %-10s %s\n' "$serial" "$kind" "${model:-?}"
  done < <(list_online_devices)
  [[ "$found" == "true" ]] || warn "  (none online — start an emulator or plug a phone in)"
  exit 0
fi

# Boot the project AVD and wait for it. Only reached when the target wants the
# emulator (explicitly, or as the auto fallback with nothing else online).
boot_emulator() {
  local emulator
  emulator="$(find_emulator || true)"
  if [[ -z "${emulator:-}" ]]; then
    err "Android emulator binary not found. Install the Android SDK or run ./scripts/setup.sh."
    exit 1
  fi
  if ! "$emulator" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"; then
    err "AVD '$AVD_NAME' not found. Run ./scripts/setup.sh to create it."
    exit 1
  fi
  log "Launching emulator $AVD_NAME..."
  "$emulator" -avd "$AVD_NAME" -no-snapshot-load >/dev/null 2>&1 &
  log "Waiting for the emulator to boot..."
  "$ADB" wait-for-device
  local timeout=180 elapsed=0 booted
  while (( elapsed < timeout )); do
    booted="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [[ "$booted" == "1" ]] && { log "Emulator booted."; return; }
    sleep 2; elapsed=$((elapsed + 2))
  done
  warn "Emulator boot timed out after ${timeout}s; continuing anyway."
}

# Resolve DEVICE_ID from the chosen target, booting the emulator if that is what
# the target calls for.
resolve_device() {
  if [[ -n "$DEVICE" ]]; then
    list_online_devices | grep -qx "$DEVICE" && { DEVICE_ID="$DEVICE"; return; }
    err "device '$DEVICE' is not attached/online. See: $0 --list"; exit 1
  fi
  case "$TARGET" in
    attached)
      DEVICE_ID="$(first_physical)"
      if [[ -z "$DEVICE_ID" ]]; then
        if list_online_devices | grep -q .; then
          err "Only an emulator is online. --attached is for a physical phone;"
          err "drop the flag to use the emulator, or plug a phone in."
        else
          err "No physical device online. Enable USB debugging and plug in"
          err "(see this script's --help), then: $0 --list"
        fi
        exit 1
      fi
      ;;
    emulator)
      DEVICE_ID="$(first_emulator)"
      [[ -n "$DEVICE_ID" ]] || { boot_emulator; DEVICE_ID="$(first_emulator)"; }
      [[ -n "$DEVICE_ID" ]] || { err "No emulator serial visible to adb after boot."; exit 1; }
      ;;
    auto)
      # Prefer a connected device (physical first); boot the emulator only when
      # nothing is online.
      DEVICE_ID="$(first_physical)"
      [[ -n "$DEVICE_ID" ]] || DEVICE_ID="$(list_online_devices | head -n1)"
      if [[ -z "$DEVICE_ID" ]]; then
        log "No device online; falling back to the emulator."
        boot_emulator
        DEVICE_ID="$(list_online_devices | head -n1)"
      fi
      [[ -n "$DEVICE_ID" ]] || { err "No device serial visible to adb."; exit 1; }
      ;;
  esac
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
  log "Mock mode — simulated BLE devices."
  DEFINES+=("--dart-define=LIBERATED_BREAD_MOCK=true")
fi

# ── live: flutter run (tethered) ─────────────────────────────────────────────

if [[ "$ACTION" == "live" ]]; then
  ARGS=("run" "-d" "$DEVICE_ID")
  [[ "$RELEASE" == "true" ]] && ARGS+=("--release")
  ARGS+=("${DEFINES[@]}")
  (( ${#PASSTHROUGH[@]} > 0 )) && ARGS+=("${PASSTHROUGH[@]}")
  log "Live (hot reload). Press r to reload, q to quit."
  log "flutter ${ARGS[*]}"
  exec flutter "${ARGS[@]}"
fi

# ── sideload / copy: both build an APK ───────────────────────────────────────

(( ${#PASSTHROUGH[@]} > 0 )) && \
  warn "Ignoring passthrough args ${PASSTHROUGH[*]} — they only apply to the live action."

BUILD_TYPE=$([[ "$RELEASE" == "true" ]] && echo release || echo debug)
APK="build/app/outputs/flutter-apk/app-${BUILD_TYPE}.apk"

log "Building the ${BUILD_TYPE} APK..."
BUILD_ARGS=("build" "apk" "--${BUILD_TYPE}")
BUILD_ARGS+=("${DEFINES[@]}")
flutter "${BUILD_ARGS[@]}"
[[ -f "$APK" ]] || { err "Expected APK not found at $APK after the build."; exit 1; }

if [[ "$ACTION" == "copy" ]]; then
  # Push the FILE, do not install. Timestamped so repeated copies don't clobber.
  stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo build)"
  dest="/sdcard/Download/liberated-bread-${BUILD_TYPE}-${stamp}.apk"
  log "Copying $APK to the phone..."
  "$ADB" -s "$DEVICE_ID" push "$APK" "$dest"
  log "Copied to $dest on $DEVICE_ID."
  log "Install on the phone: Files → Download → that .apk (allow \"install"
  log "unknown apps\" for your file manager the first time)."
  log "The same APK is on this machine at: $APK"
  exit 0
fi

# sideload: install → (optionally) launch, standalone.
log "Installing $APK on $DEVICE_ID (reinstall, keep data)..."
# -r reinstall keeping data; -d allow a version-code downgrade during dev.
"$ADB" -s "$DEVICE_ID" install -r -d "$APK"

if [[ "$LAUNCH" == "true" ]]; then
  log "Launching $PACKAGE_ID..."
  # monkey + the LAUNCHER category resolves and starts the main activity
  # without hardcoding its name.
  "$ADB" -s "$DEVICE_ID" shell monkey -p "$PACKAGE_ID" \
    -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
    || warn "Installed, but could not auto-launch — open it from the app drawer."
  log "Installed and launched. It runs on its own now; you can unplug."
else
  log "Installed (not launched). Open it from the app drawer when ready."
fi
log "Logs, if you want them: $ADB -s $DEVICE_ID logcat --pid=\$($ADB -s $DEVICE_ID shell pidof $PACKAGE_ID)"
