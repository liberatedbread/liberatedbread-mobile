#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Boot (or wait for) the project emulator for scripts/run-android.sh. Sourced,
# not executed, so scripts/android-emulator-boot-selftest.sh can drive it
# against stub `adb` and `emulator` binaries.
#
# The caller provides: ADB (the adb binary), AVD_NAME, log/err, and
# find_emulator (prints the emulator binary, or nothing).
#
#   adb_devices_states  "serial state" for EVERY attached device, whatever
#                       its state.
#   report_unusable_devices
#                       explains each attached phone adb cannot use yet;
#                       returns 0 if it reported one.
#   emulator_available  the emulator binary exists and AVD_NAME is created.
#   boot_emulator       sets BOOTED_SERIAL to a booted emulator of AVD_NAME,
#                       or exits 1 saying why. LB_EMULATOR_BOOT_TIMEOUT and
#                       LB_EMULATOR_POLL_SECS (whole seconds) tune the wait.
#   auto_fallback_emulator
#                       run-android.sh's auto mode with nothing online: the
#                       same contract as boot_emulator, or exits 1 when a
#                       phone needs attention or no emulator is set up.

# BOOTED_SERIAL is this file's output, read only by the sourcing script.
# shellcheck disable=SC2034

# "serial state" for EVERY attached device, whatever its state — so an
# unauthorized or offline phone is visible, not silently treated as absent.
adb_devices_states() {
  "$ADB" devices 2>/dev/null | awk 'NR>1 && NF>=2 {print $1, $2}'
}

# Explain every attached-but-unusable phone — the near-universal cause of "no
# device online" when a phone IS plugged in. Returns 0 if it reported one.
# An offline emulator-* serial is not a phone: it is one still booting or a
# stale entry, both of which boot_emulator handles. Counting it here made
# auto mode exit 1 ("unplug and replug it") on a re-run while the AVD was
# still booting, before it reached boot_emulator's wait.
report_unusable_devices() {
  local found=1 serial state
  while read -r serial state; do
    [[ -z "$serial" ]] && continue
    case "$state" in
      unauthorized)
        found=0
        err "Device $serial is attached but UNAUTHORIZED."
        err "  Unlock the phone and tap Allow on the 'Allow USB debugging?'"
        err "  prompt (tick \"Always allow from this computer\"), then re-run." ;;
      offline)
        [[ "$serial" == emulator-* ]] && continue
        found=0
        err "Device $serial is attached but OFFLINE."
        err "  Unplug and replug it, or run: $ADB reconnect offline" ;;
    esac
  done < <(adb_devices_states)
  return $found
}

# Whether the project emulator can actually be launched: the binary exists
# and the AVD has been created. Lets auto mode avoid promising a fallback it
# cannot deliver.
emulator_available() {
  local e; e="$(find_emulator || true)"
  [[ -n "$e" ]] && "$e" -list-avds 2>/dev/null | grep -qx "$AVD_NAME"
}

# The AVD an emulator serial is running, from its console, or nothing. A
# dead emulator that adb still lists as offline has no console to answer,
# which is what tells a stale entry apart from one that is still booting.
emulator_avd_name() {
  "$ADB" -s "$1" emu avd name 2>/dev/null | head -n1 | tr -d '\r' || true
}

# The first attached emulator whose console says it runs AVD_NAME, or
# nothing. "pending" only considers serials not yet in the "device" state;
# "any" takes any state.
attached_avd_emulator() {
  local want="$1" serial state
  while read -r serial state; do
    [[ "$serial" == emulator-* ]] || continue
    [[ "$want" == "pending" && "$state" == "device" ]] && continue
    if [[ "$(emulator_avd_name "$serial")" == "$AVD_NAME" ]]; then
      echo "$serial"
      return
    fi
  done < <(adb_devices_states)
}

# Sets BOOTED_SERIAL to the emulator it booted. Every adb call after launch
# names that serial: with a phone also online (`--emulator` promises to work
# then), a bare `adb wait-for-device` returned at once and a bare
# `adb shell getprop` either read the PHONE's sys.boot_completed (so "booted"
# was logged before the emulator existed) or failed with "more than one
# device" until the 180 s ran out and the script went on anyway.
BOOTED_SERIAL=""
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
  local serial="" pid="" before=""
  # Re-running while this AVD is still booting (attached, not yet "device")
  # must wait for it: a second launch of an AVD in use exits at once, which
  # read as "the emulator process exited before it booted" and exit 1.
  serial="$(attached_avd_emulator pending)"
  if [[ -n "$serial" ]]; then
    log "Emulator $serial ($AVD_NAME) is already starting; waiting for it."
  else
    # Emulators already attached in ANY state, so the new one can be told
    # apart from a half-registered leftover.
    before="$(adb_devices_states | awk '$1 ~ /^emulator-/ {printf "%s ", $1}')"
    log "Launching emulator $AVD_NAME..."
    "$emulator" -avd "$AVD_NAME" -no-snapshot-load >/dev/null 2>&1 &
    pid=$!
  fi
  log "Waiting for the emulator to boot..."
  local timeout="${LB_EMULATOR_BOOT_TIMEOUT:-180}"
  local poll="${LB_EMULATOR_POLL_SECS:-2}"
  local elapsed=0 booted
  while (( elapsed < timeout )); do
    if [[ -z "$serial" && -n "$pid" ]]; then
      serial="$(adb_devices_states | awk -v before="$before" '
        BEGIN { n = split(before, b, " "); for (i = 1; i <= n; i++) old[b[i]] = 1 }
        $1 ~ /^emulator-/ && !($1 in old) { print $1; exit }')"
    fi
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      # Our launch is gone. If it lost to an instance of this AVD that came
      # up between the check above and the launch, that instance is the one
      # to wait for; only with none attached is this a real failure.
      pid=""
      [[ -n "$serial" ]] || serial="$(attached_avd_emulator any)"
      if [[ -z "$serial" ]]; then
        err "The emulator process exited before it booted."
        err "  Run: $(printf '%q' "$emulator") -avd $AVD_NAME  to see why."
        exit 1
      fi
    fi
    if [[ -n "$serial" ]]; then
      booted="$("$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null \
        | tr -d '\r' || true)"
      if [[ "$booted" == "1" ]]; then
        log "Emulator $serial booted."
        BOOTED_SERIAL="$serial"
        return
      fi
    fi
    sleep "$poll"; elapsed=$((elapsed + poll))
  done
  # Carrying on here handed flutter/adb an emulator that was still booting (or
  # none at all), so the failure surfaced later as an unrelated install error.
  err "Emulator did not finish booting within ${timeout}s."
  exit 1
}

# run-android.sh's auto mode when nothing is online: sets BOOTED_SERIAL like
# boot_emulator, or exits 1 saying why.
auto_fallback_emulator() {
  # If a phone is attached but unauthorized/offline, that is almost certainly
  # what the user meant — say how to fix it rather than boot the emulator
  # behind their back (and then fail on a missing AVD).
  if report_unusable_devices; then
    err "A device is attached but not usable yet (above). Authorize it, or"
    err "pass --emulator to use the emulator instead."
    exit 1
  fi
  # Nothing connected. Boot the emulator only if it is actually set up;
  # otherwise say so plainly instead of "falling back" to a failure.
  if ! emulator_available; then
    err "Nothing to run on: no phone connected, and the '$AVD_NAME' emulator"
    err "is not set up here."
    err "  Phone:    enable USB debugging, plug it in, accept the prompt, re-run"
    err "            (then '$0 --list' should show it as 'ready')."
    err "  Emulator: install the SDK cmdline-tools + emulator, then"
    err "            ./scripts/setup.sh creates the AVD."
    exit 1
  fi
  log "No Android device online; falling back to the $AVD_NAME emulator."
  boot_emulator
}
