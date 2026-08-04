#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — build and run on the Linux desktop (x86-64)
#
# This is the fast local iteration loop: no emulator to boot, no simulator, no
# device to pair. `flutter run -d linux` builds a native GTK app and gives you
# hot reload on the same Dart UI code that ships on Android and iOS.
#
# BLE ON LINUX: flutter_blue_plus is federated, and its Linux implementation
# (flutter_blue_plus_linux) talks to BlueZ over D-Bus. That is REAL Bluetooth —
# it needs a real adapter, bluetoothd running, and your user in the `bluetooth`
# group. Containers, VMs and CI machines have none of that, so use --mock there
# (and any time you are only iterating on UI). See the --mock notes below.
#
# Usage:
#   ./scripts/run-linux.sh                    # Real BLE via BlueZ (needs an adapter)
#   ./scripts/run-linux.sh --mock             # Simulated BLE devices — no hardware
#   ./scripts/run-linux.sh --release          # Release build
#   ./scripts/run-linux.sh --headless --mock  # Run under Xvfb (no display)
#   ./scripts/run-linux.sh --device linux     # Override the Flutter device id
#   ./scripts/run-linux.sh --mock -- --verbose
#                                             # Pass extra args to `flutter run`

set -euo pipefail

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/.flutter-sdk}"
export PATH="${FLUTTER_HOME}/bin:$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[linux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[linux]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[linux]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: run-linux.sh [options] [-- <extra args for flutter run>]

Options:
  --mock            Use simulated BLE devices (no Bluetooth hardware needed).
                    The right choice for UI work, containers, VMs and CI.
  --release         Build in release mode instead of debug (no hot reload).
  --headless        Run under Xvfb, for machines with no display. Implies a
                    virtual X server; useful for smoke-testing that the app
                    actually starts. Requires xvfb-run.
  --device <id>     Flutter device id to target (default: linux).
  -h, --help        Show this help.

Everything after `--` is passed straight through to `flutter run`.

Notes:
  Real BLE on Linux goes through BlueZ over D-Bus (flutter_blue_plus_linux).
  It needs a physical adapter and a running bluetoothd; without one, scanning
  simply finds nothing. Use --mock instead.

  permission_handler has no Linux implementation. This is fine and deliberate:
  lib/services/real_ble_service.dart only calls it on Android, and every other
  platform falls through to "permission granted". BlueZ enforces access at the
  D-Bus level instead (add your user to the `bluetooth` group).
EOF
}

# ── parse args ───────────────────────────────────────────────────────────────

MOCK=false
RELEASE=false
HEADLESS=false
DEVICE_ID="linux"
PASSTHROUGH=()
SEEN_DDASH=false

while (( $# > 0 )); do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$1")
    shift
    continue
  fi
  case "$1" in
    --mock)     MOCK=true; shift ;;
    --release)  RELEASE=true; shift ;;
    --headless) HEADLESS=true; shift ;;
    --device)
      if [[ $# -lt 2 ]]; then
        err "--device requires a Flutter device id (e.g. \"linux\")."
        exit 1
      fi
      DEVICE_ID="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    --)         SEEN_DDASH=true; shift ;;
    *)          PASSTHROUGH+=("$1"); shift ;;
  esac
done

# ── platform check ───────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Linux" ]]; then
  err "This script targets the Linux desktop. On macOS use ./scripts/run-ios.sh,"
  err "or ./scripts/run-android.sh on either host."
  exit 1
fi

# x86-64 is the supported desktop target. Flutter can also build linux-arm64,
# but nothing in this project is tested there, so say so rather than failing
# confusingly later.
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
  warn "Host architecture is $ARCH; the supported Linux desktop target is x86-64."
  warn "The build may still work, but it is untested on this architecture."
fi

# ── tool checks ──────────────────────────────────────────────────────────────

if ! command -v flutter &>/dev/null; then
  err "Flutter not found. Run ./scripts/setup.sh first."
  exit 1
fi

# The scaffold is committed, but a fresh worktree that predates it (or a
# botched regeneration) would otherwise fail deep inside CMake.
if [[ ! -d "$PROJECT_DIR/linux" ]]; then
  err "No linux/ directory — the Linux desktop scaffold is missing."
  err "Regenerate it with:"
  err "  flutter create --platforms=linux . --project-name liberated_bread_mobile --org ca.pigscanfly"
  err "then restore APPLICATION_ID to ca.pigscanfly.liberatedbread in linux/CMakeLists.txt."
  exit 1
fi

# GTK is the single most common missing piece on a fresh Linux box, and CMake's
# own error for it is buried a long way down the build log. Check up front and
# name the exact packages.
MISSING_PKGS=()
if command -v pkg-config &>/dev/null; then
  pkg-config --exists gtk+-3.0        || MISSING_PKGS+=("libgtk-3-dev")
  pkg-config --exists libsecret-1     || MISSING_PKGS+=("libsecret-1-dev")
else
  MISSING_PKGS+=("pkg-config" "libgtk-3-dev" "libsecret-1-dev")
fi
for tool in cmake ninja clang; do
  command -v "$tool" &>/dev/null || MISSING_PKGS+=("$tool")
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
  err "Missing Linux desktop build dependencies: ${MISSING_PKGS[*]}"
  err "On Debian/Ubuntu:"
  err "  sudo apt-get update && sudo apt-get install -y \\"
  err "    clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev"
  exit 1
fi

if [[ "$HEADLESS" == "true" ]] && ! command -v xvfb-run &>/dev/null; then
  err "--headless needs xvfb-run. Install it with:"
  err "  sudo apt-get install -y xvfb"
  exit 1
fi

# ── ensure dart deps ─────────────────────────────────────────────────────────

cd "$PROJECT_DIR"

if [[ ! -d ".dart_tool" ]]; then
  log "Running flutter pub get..."
  flutter pub get
fi

# ── build flutter args ───────────────────────────────────────────────────────

FLUTTER_ARGS=("run" "-d" "$DEVICE_ID")

if [[ "$RELEASE" == "true" ]]; then
  FLUTTER_ARGS+=("--release")
fi

if [[ "$MOCK" == "true" ]]; then
  log "Mock mode enabled — using simulated BLE devices."
  FLUTTER_ARGS+=("--dart-define=LIBERATED_BREAD_MOCK=true")
else
  # Loud, because "the app runs but never finds a device" is otherwise a
  # confusing first experience on a laptop with Bluetooth switched off, and
  # flatly impossible in a container or VM.
  warn "Real BLE mode: scanning goes through BlueZ over D-Bus and needs a"
  warn "physical Bluetooth adapter with bluetoothd running."
  if command -v bluetoothctl &>/dev/null; then
    if ! bluetoothctl list 2>/dev/null | grep -q .; then
      warn "No Bluetooth controller is visible to BlueZ — scans will find nothing."
      warn "Re-run with --mock to use simulated devices instead."
    fi
  else
    warn "bluetoothctl not found, so BlueZ may not be installed at all."
    warn "Re-run with --mock to use simulated devices instead."
  fi
fi

if (( ${#PASSTHROUGH[@]} > 0 )); then
  FLUTTER_ARGS+=("${PASSTHROUGH[@]}")
fi

# ── go ───────────────────────────────────────────────────────────────────────

log "Running: flutter ${FLUTTER_ARGS[*]}"

if [[ "$HEADLESS" == "true" ]]; then
  log "Headless mode — starting a virtual X display via xvfb-run."
  # -a picks a free display number so concurrent runs cannot collide.
  exec xvfb-run -a flutter "${FLUTTER_ARGS[@]}"
fi

exec flutter "${FLUTTER_ARGS[@]}"
