#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Maybe bounce (restart) the adb server. Lists what adb can see and, when it
# sees nothing, asks whether to run `adb kill-server && adb start-server`.
# A wedged adb server, after sleep/resume or a USB hub reset or two SDKs'
# adb fighting over port 5037, shows up as "no devices" with a phone that is
# plugged in, unlocked and authorized. Restarting the server fixes it.
#
# Run it directly:
#   ./scripts/adb-maybe-bounce.sh            # list; if nothing is listed, ask to bounce
#   ./scripts/adb-maybe-bounce.sh --yes      # list; if nothing is listed, bounce without asking
#   ./scripts/adb-maybe-bounce.sh --force    # bounce even when devices are listed
#
#   Exit 0: adb lists at least one device (in any state), before or after a
#   bounce. Exit 1: it still lists none. Exit 2: bad usage, or no adb.
#
# Or source it. The Android scripts that need a device (run-android.sh,
# run-android-device-tests.sh, run.sh) do, and call adb_maybe_bounce when
# they cannot find one:
#
#   adb_maybe_bounce      prints `adb devices -l` to stderr. If it lists no
#                         device, offers to bounce the server and returns 0
#                         only if it did AND a device then showed up, which
#                         tells the caller to retry once. Any other outcome
#                         returns 1: the caller fails as it would have.
#                         Offered at most once per run (LB_ADB_BOUNCED).
#   adb_retry_after_bounce <cmd...>
#                         runs cmd; if it fails and adb_maybe_bounce
#                         bounces, runs it once more. For `adb install`,
#                         `adb push` and the like.
#   adb_bounce_server     restarts the server unconditionally and waits up to
#                         LB_ADB_SETTLE_SECS (default 5) for a device.
#   adb_has_devices       0 if adb lists any device, in any state.
#
# Uses $ADB when the caller has set it, else find_adb from
# android-device-select.sh (sourced here when needed).
#
# Asks only when stdin and stderr are a terminal, so CI and other unattended
# runs never block on the prompt; they fail as before. LB_ADB_BOUNCE
# overrides: "yes" bounces without asking, "no" never does, and "ask" is the
# default.

_adb_bounce_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_adb_say() { printf '\033[1;36m[adb]\033[0m %s\n' "$*" >&2; }

# The adb to use: $ADB if set, else find_adb's answer. Returns 1 when there
# is none.
_adb_bin() {
  if [[ -n "${ADB:-}" ]]; then
    printf '%s\n' "$ADB"
    return 0
  fi
  if ! declare -F find_adb >/dev/null; then
    # shellcheck source=android-device-select.sh
    source "$_adb_bounce_dir/android-device-select.sh"
  fi
  find_adb
}

# 0 if `adb devices` lists any device, whatever its state: an unauthorized
# or offline phone is something adb can see, and restarting its server will
# not help with that one. Skips the header and the "* daemon ..." lines
# that older adb prints on stdout when it starts a server.
adb_has_devices() {
  local adb
  adb="$(_adb_bin)" || return 1
  "$adb" devices 2>/dev/null | awk '
    /^List of devices/ { next }
    /^\*/              { next }
    NF >= 2            { found = 1 }
    END                { exit !found }'
}

_adb_list() {
  local adb="$1" out
  out="$("$adb" devices -l 2>&1 | grep -v '^\*' || true)"
  _adb_say "adb devices -l:"
  printf '%s\n' "$out" | sed 's/^/    /' >&2
}

# Restart the adb server, then give USB devices a moment to re-enumerate.
adb_bounce_server() {
  local adb settle waited=0
  adb="$(_adb_bin)" || { _adb_say "adb not found; nothing to bounce."; return 1; }
  settle="${LB_ADB_SETTLE_SECS:-5}"
  _adb_say "Restarting the adb server: $adb kill-server && $adb start-server"
  "$adb" kill-server >/dev/null 2>&1 || true
  if ! "$adb" start-server >/dev/null 2>&1; then
    _adb_say "adb start-server failed. Another adb (a second SDK, an IDE) may hold port 5037."
    return 1
  fi
  while (( waited < settle )) && ! adb_has_devices; do
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# See the header. 0 means "bounced and a device is now visible: retry".
adb_maybe_bounce() {
  local adb answer
  if ! adb="$(_adb_bin)"; then
    _adb_say "adb not found, so there are no devices to list and no server to bounce."
    return 1
  fi
  _adb_list "$adb"
  if adb_has_devices; then
    # Something is listed, so the server is answering: restarting it
    # would not change what the caller saw.
    return 1
  fi
  _adb_say "adb lists no devices."
  if [[ "${LB_ADB_BOUNCED:-0}" == "1" ]]; then
    _adb_say "The adb server was already restarted once this run; not again."
    return 1
  fi
  case "${LB_ADB_BOUNCE:-ask}" in
    yes|y|1|always) ;;
    no|n|0|never)
      return 1 ;;
    *)
      if [[ ! -t 0 || ! -t 2 ]]; then
        _adb_say "Not a terminal, so not offering to restart the adb server"
        _adb_say "  (LB_ADB_BOUNCE=yes does it unattended; ./scripts/adb-maybe-bounce.sh does it by hand)."
        return 1
      fi
      read -r -p "$(printf '\033[1;36m[adb]\033[0m') Restart the adb server and retry? [y/N] " answer || answer=""
      case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) return 1 ;;
      esac ;;
  esac
  export LB_ADB_BOUNCED=1
  adb_bounce_server || return 1
  _adb_list "$adb"
  if adb_has_devices; then
    _adb_say "adb sees a device now; retrying."
    return 0
  fi
  _adb_say "Still no devices after restarting the adb server."
  _adb_say "  Check the cable (a charge-only cable carries no data), that USB"
  _adb_say "  debugging is on, and that the phone is unlocked."
  return 1
}

# Run "$@"; if it fails, offer the bounce and, if it happened, run it once
# more. Returns the status of the last run.
adb_retry_after_bounce() {
  local rc=0
  "$@" || rc=$?
  (( rc == 0 )) && return 0
  adb_maybe_bounce || return "$rc"
  "$@"
}

# ── run directly ─────────────────────────────────────────────────────────────

_adb_bounce_main() {
  local force=false
  while (( $# > 0 )); do
    case "$1" in
      -y|--yes)   export LB_ADB_BOUNCE=yes ;;
      -f|--force) force=true ;;
      -h|--help)  sed -n '5,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *)          _adb_say "unknown option: $1 (use --help)"; return 2 ;;
    esac
    shift
  done
  local adb
  if ! adb="$(_adb_bin)"; then
    _adb_say "adb not found. Install Android platform-tools or run ./scripts/setup.sh."
    return 2
  fi
  if [[ "$force" == "true" ]]; then
    adb_bounce_server || return 1
    _adb_list "$adb"
    adb_has_devices
    return
  fi
  if adb_maybe_bounce; then
    return 0
  fi
  # adb_maybe_bounce returns 1 both for "devices were already listed" and
  # for "none, and none after"; the exit status says which.
  adb_has_devices
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  _adb_bounce_main "$@"
  exit $?
fi
