#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# OpenGreenIoT Mobile — build and run on iOS via a *remote* Mac over SSH
#
# Run this from Linux (or any non-Mac host). It rsyncs the working tree to a
# Mac you can SSH into, starts `flutter run` there against a paired iPhone
# (or the iOS Simulator with --simulator), and then watches your local files:
# every save is rsynced to the Mac and hot-reloaded on the phone
# automatically (via SIGUSR1 to the remote `flutter run --pid-file` process).
#
# No git push/pull in the iteration loop — edit locally, watch the phone.
#
# Usage:
#   ./scripts/run-remote-mac.sh --host user@mac.local            # First iPhone
#   ./scripts/run-remote-mac.sh --host mac --mock                # Simulated BLE
#   ./scripts/run-remote-mac.sh --host mac --simulator           # iOS Simulator
#   ./scripts/run-remote-mac.sh --host mac --device "My iPhone"  # Specific device
#   ./scripts/run-remote-mac.sh --host mac --list                # List devices
#   ./scripts/run-remote-mac.sh --host mac --bootstrap           # Run setup.sh on the Mac
#   ./scripts/run-remote-mac.sh --host mac --sync-only           # Just rsync and exit
#   ./scripts/run-remote-mac.sh --host mac --no-watch            # Skip the auto-reload watcher
#   ./scripts/run-remote-mac.sh --host mac --mock -- --verbose   # Extras to `flutter run`
#
# Environment variables (instead of flags):
#   OPENGREENIOT_MAC_HOST   SSH destination (e.g. holden@macbook.local)
#   OPENGREENIOT_MAC_DIR    Checkout dir on the Mac (default: opengreeniot-mobile-remote,
#                           relative to the remote $HOME)
#
# One-time setup:
#   1. Make sure you can `ssh <host>` without a password (ssh-copy-id).
#   2. On the Mac: install Xcode and pair your iPhone (see docs/ios-from-linux.md).
#   3. First run: ./scripts/run-remote-mac.sh --host <host> --bootstrap
#      (installs Flutter/Rust/CocoaPods deps on the Mac via scripts/setup.sh).
#
# While `flutter run` is attached you can still press r / R / q manually —
# the SSH session forwards your keystrokes. The watcher just saves you the
# push/pull/reload dance: edit a file locally and the phone updates in ~1-3 s.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;32m[remote-mac]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[remote-mac]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[remote-mac]\033[0m %s\n' "$*" >&2; }

# ── parse args ───────────────────────────────────────────────────────────────

HOST="${OPENGREENIOT_MAC_HOST:-}"
REMOTE_DIR="${OPENGREENIOT_MAC_DIR:-opengreeniot-mobile-remote}"
MOCK=false
RELEASE=false
SIMULATOR=false
DEVICE_ID=""
LIST_ONLY=false
BOOTSTRAP=false
SYNC_ONLY=false
WATCH=true
PASSTHROUGH=()
SEEN_DDASH=false

while (( $# > 0 )); do
  if [[ "$SEEN_DDASH" == "true" ]]; then
    PASSTHROUGH+=("$1"); shift; continue
  fi
  case "$1" in
    --host)
      [[ $# -lt 2 ]] && { err "--host requires an SSH destination (e.g. user@mac.local)."; exit 1; }
      HOST="$2"; shift 2 ;;
    --remote-dir)
      [[ $# -lt 2 ]] && { err "--remote-dir requires a path."; exit 1; }
      REMOTE_DIR="$2"; shift 2 ;;
    --device)
      [[ $# -lt 2 ]] && { err "--device requires a UDID or device name."; exit 1; }
      DEVICE_ID="$2"; shift 2 ;;
    --mock)      MOCK=true; shift ;;
    --release)   RELEASE=true; shift ;;
    --simulator) SIMULATOR=true; shift ;;
    --list)      LIST_ONLY=true; shift ;;
    --bootstrap) BOOTSTRAP=true; shift ;;
    --sync-only) SYNC_ONLY=true; shift ;;
    --no-watch)  WATCH=false; shift ;;
    --)          SEEN_DDASH=true; shift ;;
    *)           PASSTHROUGH+=("$1"); shift ;;
  esac
done

if [[ -z "$HOST" ]]; then
  err "No remote Mac specified."
  err "Pass --host user@mac.local or set OPENGREENIOT_MAC_HOST."
  exit 1
fi

for cmd in ssh rsync; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd not found. Install it (e.g. apt install openssh-client rsync)."
    exit 1
  fi
done

# ── ssh connection multiplexing ──────────────────────────────────────────────
# One master connection; every subsequent ssh/rsync reuses it, so the
# sync-on-save loop doesn't pay a handshake each time.

CTRL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ogiot-ssh.XXXXXX")"
CTRL_PATH="$CTRL_DIR/ctl"
SSH_OPTS=(
  -o ControlMaster=auto
  -o ControlPath="$CTRL_PATH"
  -o ControlPersist=60
  -o ServerAliveInterval=15
)

ssh_run()  { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
# -t allocates a tty so `flutter run` is interactive (r/R/q work) and dies
# with the connection instead of lingering on the Mac.
ssh_tty()  { ssh -t "${SSH_OPTS[@]}" "$HOST" "$@"; }

REMOTE_PIDFILE="/tmp/opengreeniot-flutter-$$.pid"
WATCHER_PID=""

cleanup() {
  if [[ -n "$WATCHER_PID" ]] && kill -0 "$WATCHER_PID" 2>/dev/null; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  ssh_run "rm -f '$REMOTE_PIDFILE'" 2>/dev/null || true
  ssh -O exit -o ControlPath="$CTRL_PATH" "$HOST" 2>/dev/null || true
  rm -rf "$CTRL_DIR"
}
trap cleanup EXIT INT TERM

log "Connecting to $HOST..."
REMOTE_OS="$(ssh_run 'uname -s' 2>/dev/null || true)"
if [[ -z "$REMOTE_OS" ]]; then
  err "Could not SSH to '$HOST'."
  err "Check the hostname and that key-based auth works: ssh $HOST"
  exit 1
fi
if [[ "$REMOTE_OS" != "Darwin" ]]; then
  err "Remote host '$HOST' is $REMOTE_OS, not macOS. iOS builds need a Mac."
  exit 1
fi

# ── sync the working tree ────────────────────────────────────────────────────
# Excludes are build outputs and per-machine state; rsync --delete won't
# remove excluded paths on the Mac, so its caches (rust/target, Pods,
# .dart_tool) survive between syncs and rebuilds stay incremental.

RSYNC_EXCLUDES=(
  --exclude '.git/'
  --exclude 'build/'
  --exclude '.dart_tool/'
  --exclude 'rust/target/'
  --exclude 'ios/Pods/'
  --exclude 'ios/.symlinks/'
  --exclude 'ios/Flutter/ephemeral/'
  --exclude 'macos/Pods/'
  --exclude 'macos/Flutter/ephemeral/'
  --exclude 'android/.gradle/'
  --exclude 'android/local.properties'
  --exclude '.idea/'
  --exclude '*.iml'
  --exclude '.flutter-plugins'
  --exclude '.flutter-plugins-dependencies'
)

sync_tree() {
  rsync -az --delete "${RSYNC_EXCLUDES[@]}" \
    -e "ssh ${SSH_OPTS[*]}" \
    "$PROJECT_DIR/" "$HOST:$REMOTE_DIR/"
}

log "Syncing working tree to $HOST:$REMOTE_DIR ..."
ssh_run "mkdir -p '$REMOTE_DIR'"
sync_tree
log "Sync complete."

if [[ "$SYNC_ONLY" == "true" ]]; then
  exit 0
fi

# ── bootstrap / tool checks on the Mac ───────────────────────────────────────

if [[ "$BOOTSTRAP" == "true" ]]; then
  log "Running scripts/setup.sh on $HOST (first run takes a while)..."
  ssh_tty "cd '$REMOTE_DIR' && ./scripts/setup.sh"
fi

if ! ssh_run "export PATH=\"\${FLUTTER_HOME:-\$HOME/.flutter-sdk}/bin:\$PATH\"; command -v flutter" >/dev/null 2>&1; then
  err "Flutter not found on $HOST."
  err "Run once with --bootstrap to install the toolchain there:"
  err "  ./scripts/run-remote-mac.sh --host $HOST --bootstrap"
  exit 1
fi

# ── list devices ─────────────────────────────────────────────────────────────

if [[ "$LIST_ONLY" == "true" ]]; then
  ssh_run "cd '$REMOTE_DIR' && ./scripts/run-ios-device.sh --list"
  exit 0
fi

# ── build the remote run command ─────────────────────────────────────────────
# Reuse the on-Mac scripts (they handle pub get, pod install, device
# selection). --pid-file makes the remote `flutter run` write its PID so the
# watcher can poke it with SIGUSR1 (hot reload) after each sync.

if [[ "$SIMULATOR" == "true" ]]; then
  RUN_SCRIPT="./scripts/run-ios.sh"
else
  RUN_SCRIPT="./scripts/run-ios-device.sh"
fi

RUN_ARGS=()
[[ "$MOCK" == "true" ]]    && RUN_ARGS+=(--mock)
[[ "$RELEASE" == "true" ]] && RUN_ARGS+=(--release)
[[ -n "$DEVICE_ID" ]]      && RUN_ARGS+=(--device "$DEVICE_ID")
RUN_ARGS+=(-- --pid-file "$REMOTE_PIDFILE")
if (( ${#PASSTHROUGH[@]} > 0 )); then
  RUN_ARGS+=("${PASSTHROUGH[@]}")
fi

REMOTE_CMD="cd '$REMOTE_DIR' && $RUN_SCRIPT"
for a in "${RUN_ARGS[@]}"; do
  REMOTE_CMD+=" $(printf '%q' "$a")"
done

# ── local watcher: sync on save, hot reload on the phone ─────────────────────

reload_remote() {
  # SIGUSR1 → hot reload; the pidfile appears once flutter attaches.
  ssh_run "[ -f '$REMOTE_PIDFILE' ] && kill -USR1 \"\$(cat '$REMOTE_PIDFILE')\"" \
    2>/dev/null || true
}

handle_change() {
  local changed="$1"
  sync_tree || { warn "Sync failed; will retry on next change."; return; }
  if grep -Eq '(^|/)rust/|(^|/)pubspec\.yaml$|(^|/)ios/|(^|/)android/' <<<"$changed"; then
    warn "Native/dependency change detected — hot reload won't pick it up."
    warn "Quit (q) and re-run this script for a full rebuild."
  fi
  reload_remote
  log "Synced + hot reloaded ($(head -1 <<<"$changed" | sed "s|^$PROJECT_DIR/||")...)"
}

watch_loop() {
  cd "$PROJECT_DIR"
  local paths=(lib assets rust pubspec.yaml ios android)
  local existing=()
  for p in "${paths[@]}"; do [[ -e "$p" ]] && existing+=("$p"); done

  if command -v inotifywait &>/dev/null; then
    log "Watching for changes with inotifywait..."
    inotifywait -m -r -q \
      -e close_write -e create -e delete -e moved_to -e moved_from \
      --format '%w%f' \
      --exclude '(^|/)(\.git|build|\.dart_tool)(/|$)|(^|/)rust/target(/|$)|/\.[^/]*$' \
      "${existing[@]}" |
    while read -r path; do
      # Debounce: drain events that arrive within 200 ms of the first.
      local batch="$path" more
      while read -r -t 0.2 more; do batch+=$'\n'"$more"; done
      handle_change "$batch"
    done
  elif command -v fswatch &>/dev/null; then
    log "Watching for changes with fswatch..."
    fswatch -r --event Updated --event Created --event Removed \
      -e '(^|/)(\.git|build|\.dart_tool)(/|$)' -e '(^|/)rust/target(/|$)' \
      "${existing[@]}" |
    while read -r path; do
      local batch="$path" more
      while read -r -t 0.2 more; do batch+=$'\n'"$more"; done
      handle_change "$batch"
    done
  else
    warn "Neither inotifywait nor fswatch found — polling every second."
    warn "For instant reloads: apt install inotify-tools"
    local stamp
    stamp="$(mktemp "$CTRL_DIR/stamp.XXXXXX")"
    while true; do
      sleep 1
      touch "$stamp.new"
      local changed
      changed="$(find "${existing[@]}" -type f -newer "$stamp" \
        -not -path '*/.*' -not -path '*rust/target*' 2>/dev/null | head -20)"
      mv "$stamp.new" "$stamp"
      [[ -n "$changed" ]] && handle_change "$changed"
    done
  fi
}

if [[ "$RELEASE" == "true" && "$WATCH" == "true" ]]; then
  warn "Release build — hot reload unavailable, disabling the watcher."
  WATCH=false
fi

if [[ "$WATCH" == "true" ]]; then
  watch_loop &
  WATCHER_PID=$!
  log "Auto-reload active: edits under lib/ and assets/ sync to the Mac and"
  log "hot reload on the device automatically. Manual keys still work (r/R/q)."
else
  log "Watcher disabled — re-run without --no-watch for sync-on-save."
fi

# ── run ──────────────────────────────────────────────────────────────────────

log "Starting on $HOST: $REMOTE_CMD"
ssh_tty "$REMOTE_CMD"
