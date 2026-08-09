#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Run a command against a virtual BlueZ stack: emulated BLE peripherals, no
# radio, no kernel module, no root.
#
# HOW IT WORKS
#
# On Linux the app's real BLE path is flutter_blue_plus_linux, and that talks to
# BlueZ over D-Bus rather than to hardware. So this starts a PRIVATE dbus-daemon,
# points DBUS_SYSTEM_BUS_ADDRESS at it, and runs scripts/ble_virtual_peripheral.py
# there under the name `org.bluez`. Both libdbus and package:dbus honour that
# variable, so every BlueZ client the command starts — the app, or plain
# `bluetoothctl` — reaches the emulated stack instead of the real one.
#
# Nothing touches the machine's actual Bluetooth: the private bus is a fresh
# socket in a temporary directory and is torn down on exit. The peripheral
# script refuses to run without DBUS_SYSTEM_BUS_ADDRESS set, so it cannot claim
# org.bluez on the real system bus by accident.
#
# WHY NOT btvirt / hci_vhci
#
# The kernel route (`modprobe hci_vhci` + `btvirt -l`) is the other way to get a
# virtual controller, and it is a truer emulation: a real HCI device, real
# bluetoothd. It also needs root, a loadable-module kernel, and /dev/vhci — none
# of which a container has, and the failure mode inside one is
# "Failed to open Virtual HCI device" with nothing to do about it. This route
# needs nothing but a D-Bus session, so it runs anywhere the tests run.
#
# Usage:
#   ./scripts/linux-virtual-ble.sh bluetoothctl devices
#   ./scripts/linux-virtual-ble.sh xvfb-run -a flutter test \
#       integration_test/linux_virtual_ble_test.dart -d linux
#
# Environment:
#   LB_VIRTUAL_BLE_SCENARIO   JSON device list to serve instead of the bundled
#                             one (see ble_virtual_peripheral.py --scenario).

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 64
fi

for tool in dbus-daemon python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::$tool is not installed; the virtual BlueZ stack needs it." >&2
    exit 1
  fi
done

if ! python3 -c 'import dbus_next' 2>/dev/null; then
  echo "::error::python3-dbus-next is not installed. Install it with" >&2
  echo "  sudo apt-get install -y python3-dbus-next   (or: pip install dbus-next)" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
BUS_PID=""
PERIPHERAL_PID=""

# The exit status is whatever triggered the trap; nothing here changes it.
# shellcheck disable=SC2317  # reached through `trap`, which shellcheck cannot see
cleanup() {
  if [ -n "$PERIPHERAL_PID" ]; then
    kill "$PERIPHERAL_PID" 2>/dev/null || true
  fi
  if [ -n "$BUS_PID" ]; then
    kill "$BUS_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --print-address/--print-pid write one line each, in that order.
{
  read -r BUS_ADDRESS
  read -r BUS_PID
} < <(dbus-daemon --session --print-address=1 --print-pid=1 --fork)

# The name is the whole trick: a BlueZ client asks for the SYSTEM bus, and this
# is what tells it where that bus lives.
export DBUS_SYSTEM_BUS_ADDRESS="$BUS_ADDRESS"

READY_FILE="$WORK_DIR/ready"
scenario_args=()
if [ -n "${LB_VIRTUAL_BLE_SCENARIO:-}" ]; then
  scenario_args=(--scenario "$LB_VIRTUAL_BLE_SCENARIO")
fi

python3 scripts/ble_virtual_peripheral.py \
  --ready-file "$READY_FILE" "${scenario_args[@]}" &
PERIPHERAL_PID=$!

# Wait on the fact that org.bluez is claimed, not on a sleep — a fixed sleep is
# either too short on a loaded CI runner or wasted time on a laptop.
for _ in $(seq 1 100); do
  [ -f "$READY_FILE" ] && break
  if ! kill -0 "$PERIPHERAL_PID" 2>/dev/null; then
    echo "::error::the virtual peripheral exited before claiming org.bluez" >&2
    exit 1
  fi
  sleep 0.1
done

if [ ! -f "$READY_FILE" ]; then
  echo "::error::the virtual peripheral did not claim org.bluez within 10s" >&2
  exit 1
fi

echo "[virtual-ble] org.bluez served on $DBUS_SYSTEM_BUS_ADDRESS"

set +e
"$@"
status=$?
set -e
exit "$status"
