#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — build and launch on iOS Simulator (macOS only)
#
# Boots the latest available iPhone simulator (or one chosen with --device),
# then builds and runs the app via `flutter run`.
#
# Usage:
#   ./scripts/run-ios.sh                       # Latest iPhone simulator
#   ./scripts/run-ios.sh --mock                # Simulated BLE devices
#   ./scripts/run-ios.sh --release             # Release build
#   ./scripts/run-ios.sh --device "iPhone 15"  # Pick a specific simulator
#   ./scripts/run-ios.sh --mock -- --verbose   # Pass extras to `flutter run`

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[ios]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ios]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ios]\033[0m %s\n' "$*" >&2; }

# Auto-upgrades the repo-managed SDK at ~/.flutter-sdk to CI's pinned Flutter.
# shellcheck source=flutter-ensure-version.sh
source "$SCRIPT_DIR/flutter-ensure-version.sh"
source "$SCRIPT_DIR/regen-bindings.sh"

# ── platform check ───────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "iOS builds require macOS. Use ./scripts/run-android.sh on this host."
  exit 1
fi

# ── parse args ───────────────────────────────────────────────────────────────

MOCK=false
RELEASE=false
DEVICE_NAME=""
PASSTHROUGH=()
SEEN_DDASH=false

while (( $# > 0 )); do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$1")
    shift
    continue
  fi
  case "$1" in
    --mock)    MOCK=true; shift ;;
    --release) RELEASE=true; shift ;;
    --device)
      if [[ $# -lt 2 ]]; then
        err "--device requires a simulator name (e.g. \"iPhone 15\")."
        exit 1
      fi
      DEVICE_NAME="$2"; shift 2 ;;
    --)        SEEN_DDASH=true; shift ;;
    *)         PASSTHROUGH+=("$1"); shift ;;
  esac
done

# ── tool checks ──────────────────────────────────────────────────────────────

if ! command -v flutter &>/dev/null; then
  err "Flutter not found. Run ./scripts/setup.sh first."
  exit 1
fi

# Follow CI's Flutter pin: upgrade ~/.flutter-sdk in place when it is stale, so
# a version bump in ci.yml doesn't turn into a confusing `flutter pub get`
# failure here. A Flutter installed elsewhere is left alone. (LB_FLUTTER_AUTO_UPGRADE=0 skips.)
flutter_ensure_ci_version

if ! xcode-select -p &>/dev/null; then
  err "Xcode not installed. Install it from the App Store."
  exit 1
fi

if ! command -v xcrun &>/dev/null; then
  err "xcrun not on PATH. Install Xcode command line tools."
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  err "python3 not found (expected to ship with macOS)."
  exit 1
fi

# ── ensure dart deps ─────────────────────────────────────────────────────────

cd "$PROJECT_DIR"
# A rebuild that reflects the current Rust: regenerate the FFI bindings if the
# Rust API changed since they were last generated (no-op otherwise).
regen_frb_bindings
if [[ ! -d ".dart_tool" ]]; then
  log "Running flutter pub get..."
  flutter pub get
fi

# ── pod install (first run, or when Podfile changes) ─────────────────────────

if [[ -f "$PROJECT_DIR/ios/Podfile" ]]; then
  if ! command -v pod &>/dev/null; then
    err "CocoaPods not installed. Run: sudo gem install cocoapods"
    exit 1
  fi
  if [[ ! -f "$PROJECT_DIR/ios/Podfile.lock" ]] \
    || [[ "$PROJECT_DIR/ios/Podfile" -nt "$PROJECT_DIR/ios/Podfile.lock" ]]; then
    log "Running pod install..."
    (cd "$PROJECT_DIR/ios" && pod install)
  fi
fi

# ── pick a simulator UDID ────────────────────────────────────────────────────

# Returns a UDID for the requested device, or the newest available iPhone
# if no name was provided. Uses python3 to walk simctl's JSON output.
#
# python3 fetches the JSON itself rather than reading it from a pipe. It used
# to be `xcrun simctl … | python3 - "$DEVICE_NAME" <<'PY'`, which cannot work:
# `python3 -` reads the PROGRAM from stdin, the heredoc is what supplies stdin,
# and so the pipe was overridden and `json.load(sys.stdin)` got EOF. Every call
# raised JSONDecodeError, `$(pick_simulator)` came back empty, and the script
# stopped at "Could not select a simulator." (shellcheck SC2259 names exactly
# this; it is why the CI lint gate over scripts/ exists.)
pick_simulator() {
  python3 - "$DEVICE_NAME" <<'PY'
import json, re, subprocess, sys

want = sys.argv[1] if len(sys.argv) > 1 else ""
data = json.loads(subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "--json"],
    check=True, capture_output=True, text=True).stdout)
devs_by_runtime = data.get("devices", {})

def runtime_key(rt):
    # e.g. "com.apple.CoreSimulator.SimRuntime.iOS-17-2" -> (17, 2)
    m = re.search(r"iOS[-_](\d+)[-_.](\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)

candidates = []  # (runtime_tuple, name, udid, state)
for runtime, devs in devs_by_runtime.items():
    if "iOS" not in runtime:
        continue
    rk = runtime_key(runtime)
    for d in devs:
        if not d.get("isAvailable", True):
            continue
        candidates.append((rk, d["name"], d["udid"], d.get("state", "")))

if want:
    matches = [c for c in candidates if c[1] == want]
    if not matches:
        sys.stderr.write(f"No available iOS simulator named {want!r}.\n")
        sys.exit(2)
    matches.sort(key=lambda c: c[0], reverse=True)
    print(matches[0][2])
else:
    iphones = [c for c in candidates if c[1].startswith("iPhone ")]
    if not iphones:
        sys.stderr.write("No available iPhone simulators found.\n")
        sys.exit(2)
    iphones.sort(key=lambda c: (c[0], c[1]), reverse=True)
    print(iphones[0][2])
PY
}

UDID="$(pick_simulator)"
if [[ -z "$UDID" ]]; then
  err "Could not select a simulator."
  exit 1
fi

if [[ -n "$DEVICE_NAME" ]]; then
  log "Using simulator: $DEVICE_NAME ($UDID)"
else
  log "Using newest available iPhone simulator: $UDID"
fi

# ── boot the simulator ───────────────────────────────────────────────────────

STATE="$(xcrun simctl list devices --json \
  | python3 -c "
import json, sys
udid = '$UDID'
data = json.load(sys.stdin)
for devs in data.get('devices', {}).values():
    for d in devs:
        if d['udid'] == udid:
            print(d.get('state', ''))
            sys.exit(0)
")"

if [[ "$STATE" != "Booted" ]]; then
  log "Booting simulator..."
  xcrun simctl boot "$UDID"
else
  log "Simulator already booted."
fi

# Bring up the Simulator window so the user can see it.
open -a Simulator

log "Waiting for simulator to finish booting..."
xcrun simctl bootstatus "$UDID" -b >/dev/null

# ── build flutter args ───────────────────────────────────────────────────────

FLUTTER_ARGS=("run" "-d" "$UDID")

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
