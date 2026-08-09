#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""A virtual BlueZ stack: emulated BLE peripherals served as `org.bluez`.

WHAT THIS IS FOR

On Linux the app's real BLE path is flutter_blue_plus_linux, which does not
talk to a radio directly — it talks to BlueZ's `org.bluez` D-Bus service, via
package:bluez. So the seam that matters on this platform is D-Bus, and anything
that can hold the `org.bluez` bus name and answer the BlueZ API IS, as far as
the app is concerned, a Bluetooth stack with devices attached.

That is this script. It needs no Bluetooth hardware, no `hci_vhci` kernel
module, and no root: run a private `dbus-daemon`, point DBUS_SYSTEM_BUS_ADDRESS
at it (both libdbus and package:dbus honour that variable), and every BlueZ
client on the machine — `bluetoothctl` included — sees the emulated devices.
scripts/linux-virtual-ble.sh does that wiring.

WHY IT EXISTS ALONGSIDE test/fakes/emulated_ble.dart

The Dart emulator substitutes flutter_blue_plus's platform interface, so it
covers everything above that line on every platform, and nothing below it. This
one sits a layer lower again: flutter_blue_plus_linux's own translation of
BlueZ semantics runs for real, which is the only way to exercise the things
that are specific to this backend — service discovery racing BlueZ's
ServicesResolved flag, StartNotify's CCCD confirmation never arriving, and
D-Bus error NAMES ("Not paired") standing in for the ATT codes every other
platform reports.

THE MODEL

  * Discovery is not free: devices appear only once StartDiscovery has been
    called, as InterfacesAdded, the same way BlueZ reports a real scan.
  * The GATT tree appears on Connect, not before, and ServicesResolved goes
    true after it — deliberately in that order, because the opposite is what
    makes a client see zero services on a device that has plenty.
  * A device may require pairing. Until Pair() succeeds its characteristics
    answer org.bluez.Error.NotPermitted / "Not paired", which is BlueZ's
    rendering of ATT 0x05.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys

try:
    from dbus_next import BusType, DBusError, PropertyAccess
    from dbus_next.aio import MessageBus
    from dbus_next.service import ServiceInterface, dbus_property, method
except ImportError:  # pragma: no cover - the wrapper script checks for this
    sys.stderr.write(
        'python3-dbus-next is not installed.\n'
        '  Ubuntu/Debian: sudo apt-get install -y python3-dbus-next\n'
        '  Otherwise:     pip install dbus-next\n'
    )
    raise SystemExit(2)

ADAPTER_PATH = '/org/bluez/hci0'
ADAPTER_ADDRESS = '00:11:22:33:44:55'

# Matches assets/device_specs/example-bulb.yaml, and test/fakes/emulated_ble.dart
# with it, so a scenario reads the same whichever emulator is running it.
CONTROL_SERVICE = '0000fff0-0000-1000-8000-00805f9b34fb'
CONTROL_COMMAND = '0000fff1-0000-1000-8000-00805f9b34fb'
CONTROL_STATE = '0000fff2-0000-1000-8000-00805f9b34fb'
BATTERY_SERVICE = '0000180f-0000-1000-8000-00805f9b34fb'
BATTERY_LEVEL = '00002a19-0000-1000-8000-00805f9b34fb'

DEFAULT_SCENARIO = [
    {
        'address': 'AA:BB:CC:DD:EE:01',
        'name': 'ACME_Living_Room',
        'rssi': -45,
        'requires_pairing': False,
        'services': [
            {
                'uuid': CONTROL_SERVICE,
                'characteristics': [
                    {
                        'uuid': CONTROL_COMMAND,
                        'flags': ['write-without-response'],
                        'value': [],
                    },
                    {
                        'uuid': CONTROL_STATE,
                        'flags': ['read', 'notify'],
                        'value': [1, 80, 255, 180, 50],
                    },
                ],
            },
            {
                'uuid': BATTERY_SERVICE,
                'characteristics': [
                    {
                        'uuid': BATTERY_LEVEL,
                        'flags': ['read', 'notify'],
                        'value': [85],
                    },
                ],
            },
        ],
    },
    {
        'address': 'AA:BB:CC:DD:EE:03',
        'name': 'Vault Sensor',
        'rssi': -70,
        'requires_pairing': True,
        'services': [
            {
                'uuid': BATTERY_SERVICE,
                'characteristics': [
                    {
                        'uuid': BATTERY_LEVEL,
                        'flags': ['read', 'notify'],
                        'value': [42],
                    },
                ],
            },
        ],
    },
]


class _DeliberateRefusalFilter(logging.Filter):
    """Keep dbus-next quiet about the errors this script raises on purpose.

    dbus-next logs every DBusError raised out of a method handler at ERROR
    level, with a traceback — including an unpaired peripheral refusing a read,
    which is the whole point of the pairing scenario. The refusal still reaches
    the caller; only the scary log line, printed into the middle of a PASSING
    test, is dropped. Anything else dbus-next complains about still shows.
    """

    DELIBERATE = ('Not paired', 'Authentication Rejected')

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        if 'unexpected error processing a message' not in message:
            return True
        return not any(phrase in message for phrase in self.DELIBERATE)


def device_path(address: str) -> str:
    return f"{ADAPTER_PATH}/dev_{address.replace(':', '_')}"


class Adapter1(ServiceInterface):
    """org.bluez.Adapter1 — the emulated controller."""

    def __init__(self, stack: 'VirtualStack'):
        super().__init__('org.bluez.Adapter1')
        self._stack = stack
        self._powered = True
        self._discovering = False

    @method()
    def StartDiscovery(self):
        if self._discovering:
            return
        self._discovering = True
        self.emit_properties_changed({'Discovering': True})
        # Retire first, then republish, so every scan re-announces its devices
        # as InterfacesAdded. flutter_blue_plus_linux builds scan results from
        # that signal alone, so a device left in the object tree from a previous
        # scan is invisible to this one — a second scan would come back empty
        # and look like an app bug.
        #
        # Retiring here rather than on StopDiscovery is deliberate: the scan
        # screen stops the scan and THEN connects to what it found, so a device
        # pruned at stop would be gone by the time the user taps it.
        self._stack.retire_devices()
        self._stack.publish_devices()

    @method()
    def StopDiscovery(self):
        if not self._discovering:
            return
        self._discovering = False
        self.emit_properties_changed({'Discovering': False})

    @method()
    def SetDiscoveryFilter(self, properties: 'a{sv}'):  # noqa: F821
        pass

    @method()
    def RemoveDevice(self, device: 'o'):  # noqa: F821
        pass

    @dbus_property(access=PropertyAccess.READ)
    def Address(self) -> 's':  # noqa: F821
        return ADAPTER_ADDRESS

    @dbus_property(access=PropertyAccess.READ)
    def Name(self) -> 's':  # noqa: F821
        return 'virtual-hci0'

    @dbus_property(access=PropertyAccess.READWRITE)
    def Alias(self) -> 's':  # noqa: F821
        return 'virtual-hci0'

    @Alias.setter
    def Alias(self, value: 's'):  # noqa: F821
        pass

    @dbus_property(access=PropertyAccess.READWRITE)
    def Powered(self) -> 'b':  # noqa: F821
        return self._powered

    @Powered.setter
    def Powered(self, value: 'b'):  # noqa: F821
        self._powered = value
        self.emit_properties_changed({'Powered': value})

    @dbus_property(access=PropertyAccess.READ)
    def Discovering(self) -> 'b':  # noqa: F821
        return self._discovering

    @dbus_property(access=PropertyAccess.READ)
    def UUIDs(self) -> 'as':  # noqa: F821
        return []


class GattCharacteristic1(ServiceInterface):
    """org.bluez.GattCharacteristic1 — one attribute on a virtual peripheral."""

    def __init__(self, device: 'VirtualDevice', service_path: str, config: dict):
        super().__init__('org.bluez.GattCharacteristic1')
        self._device = device
        self._service_path = service_path
        self._uuid = config['uuid']
        self._flags = list(config.get('flags', ['read']))
        self._value = bytes(config.get('value', []))
        self._notifying = False

    def _guard(self):
        """Refuse like BlueZ does when the link is not paired.

        BlueZ reports an error NAME, not an ATT number — this is the one place
        the app's pairing detection has to fall back on the description string,
        and the only way to exercise that branch for real.
        """
        if self._device.requires_pairing and not self._device.paired:
            raise DBusError('org.bluez.Error.NotPermitted', 'Not paired')

    @method()
    def ReadValue(self, options: 'a{sv}') -> 'ay':  # noqa: F821
        self._guard()
        return self._value

    @method()
    def WriteValue(self, value: 'ay', options: 'a{sv}'):  # noqa: F821
        self._guard()
        self._value = bytes(value)
        self.emit_properties_changed({'Value': self._value})

    @method()
    def StartNotify(self):
        self._guard()
        self._notifying = True
        self.emit_properties_changed({'Notifying': True})

    @method()
    def StopNotify(self):
        self._notifying = False
        self.emit_properties_changed({'Notifying': False})

    def push(self, value: bytes):
        self._value = bytes(value)
        if self._notifying:
            self.emit_properties_changed({'Value': self._value})

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> 's':  # noqa: F821
        return self._uuid

    @dbus_property(access=PropertyAccess.READ)
    def Service(self) -> 'o':  # noqa: F821
        return self._service_path

    @dbus_property(access=PropertyAccess.READ)
    def Flags(self) -> 'as':  # noqa: F821
        return self._flags

    @dbus_property(access=PropertyAccess.READ)
    def Notifying(self) -> 'b':  # noqa: F821
        return self._notifying

    @dbus_property(access=PropertyAccess.READ)
    def Value(self) -> 'ay':  # noqa: F821
        return self._value


class GattService1(ServiceInterface):
    """org.bluez.GattService1 — one primary service on a virtual peripheral."""

    def __init__(self, device_path_: str, uuid: str):
        super().__init__('org.bluez.GattService1')
        self._device_path = device_path_
        self._uuid = uuid

    @dbus_property(access=PropertyAccess.READ)
    def UUID(self) -> 's':  # noqa: F821
        return self._uuid

    @dbus_property(access=PropertyAccess.READ)
    def Device(self) -> 'o':  # noqa: F821
        return self._device_path

    @dbus_property(access=PropertyAccess.READ)
    def Primary(self) -> 'b':  # noqa: F821
        return True


class Device1(ServiceInterface):
    """org.bluez.Device1 — a virtual peripheral."""

    def __init__(self, stack: 'VirtualStack', config: dict):
        super().__init__('org.bluez.Device1')
        self._stack = stack
        self.config = config
        self.address = config['address']
        self.path = device_path(self.address)
        self.requires_pairing = bool(config.get('requires_pairing', False))
        self.paired = False
        self._connected = False
        self._services_resolved = False
        self.gatt_exported = False
        self.exported_paths: list[str] = []
        self.characteristics: dict[str, GattCharacteristic1] = {}

    @property
    def connected(self) -> bool:
        return self._connected

    @method()
    async def Connect(self):
        if self._connected:
            return
        self._connected = True
        self.emit_properties_changed({'Connected': True})
        # Export the GATT tree, THEN flag it resolved. A client that reads the
        # tree on the Connected signal alone races this and sees nothing, which
        # is the real BlueZ behaviour the app's discovery retry ladder exists
        # for — reproduce the order, not a convenient version of it.
        self._stack.export_gatt(self)
        self._services_resolved = True
        self.emit_properties_changed({'ServicesResolved': True})

    @method()
    def Disconnect(self):
        if not self._connected:
            return
        self._connected = False
        self._services_resolved = False
        self.emit_properties_changed(
            {'Connected': False, 'ServicesResolved': False}
        )

    @method()
    async def Pair(self):
        if not self.config.get('accepts_pairing', True):
            raise DBusError('org.bluez.Error.AuthenticationRejected',
                            'Authentication Rejected')
        self.paired = True
        self.emit_properties_changed({'Paired': True})

    @method()
    def CancelPairing(self):
        pass

    @dbus_property(access=PropertyAccess.READ)
    def Address(self) -> 's':  # noqa: F821
        return self.address

    @dbus_property(access=PropertyAccess.READ)
    def Name(self) -> 's':  # noqa: F821
        return self.config['name']

    @dbus_property(access=PropertyAccess.READWRITE)
    def Alias(self) -> 's':  # noqa: F821
        return self.config['name']

    @Alias.setter
    def Alias(self, value: 's'):  # noqa: F821
        pass

    @dbus_property(access=PropertyAccess.READ)
    def RSSI(self) -> 'n':  # noqa: F821
        return int(self.config.get('rssi', -60))

    @dbus_property(access=PropertyAccess.READ)
    def Connected(self) -> 'b':  # noqa: F821
        return self._connected

    @dbus_property(access=PropertyAccess.READ)
    def ServicesResolved(self) -> 'b':  # noqa: F821
        return self._services_resolved

    @dbus_property(access=PropertyAccess.READ)
    def Paired(self) -> 'b':  # noqa: F821
        return self.paired

    @dbus_property(access=PropertyAccess.READ)
    def Trusted(self) -> 'b':  # noqa: F821
        return False

    @dbus_property(access=PropertyAccess.READ)
    def Blocked(self) -> 'b':  # noqa: F821
        return False

    @dbus_property(access=PropertyAccess.READ)
    def Adapter(self) -> 'o':  # noqa: F821
        return ADAPTER_PATH

    @dbus_property(access=PropertyAccess.READ)
    def UUIDs(self) -> 'as':  # noqa: F821
        return [s['uuid'] for s in self.config.get('services', [])]


class VirtualStack:
    """Owns the bus connection and the exported object tree."""

    def __init__(self, bus: MessageBus, scenario: list[dict]):
        self.bus = bus
        self.scenario = scenario
        self.adapter = Adapter1(self)
        self.devices: dict[str, Device1] = {}

    def export_adapter(self):
        self.bus.export(ADAPTER_PATH, self.adapter)

    def publish_devices(self):
        """Make the scenario's devices visible, as a scan result would.

        Each appearance is an InterfacesAdded, which is what a BlueZ client
        reads as "found a device". A device already in the tree is left alone.
        """
        for config in self.scenario:
            address = config['address']
            if address in self.devices:
                continue
            device = Device1(self, config)
            self.devices[address] = device
            self.bus.export(device.path, device)

    def retire_devices(self):
        """Drop unconnected devices from the tree, as BlueZ prunes stale ones.

        A connected device stays: BlueZ keeps those, and unexporting one out
        from under a live GATT session would be a failure mode no real stack
        has.
        """
        for address, device in list(self.devices.items()):
            if device.connected:
                continue
            for path in device.exported_paths:
                self.bus.unexport(path)
            device.exported_paths.clear()
            device.characteristics.clear()
            device.gatt_exported = False
            self.bus.unexport(device.path)
            del self.devices[address]

    def export_gatt(self, device: Device1):
        if device.gatt_exported:
            return
        device.gatt_exported = True
        for service_index, service in enumerate(device.config.get('services', [])):
            service_path = f'{device.path}/service{service_index:04x}'
            self.bus.export(service_path, GattService1(device.path, service['uuid']))
            device.exported_paths.append(service_path)
            for char_index, char in enumerate(service.get('characteristics', [])):
                char_path = f'{service_path}/char{char_index:04x}'
                characteristic = GattCharacteristic1(device, service_path, char)
                device.characteristics[char['uuid'].lower()] = characteristic
                self.bus.export(char_path, characteristic)
                device.exported_paths.append(char_path)


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--scenario',
        help='Path to a JSON device list; the bundled two-device scenario by '
             'default (one open peripheral, one that requires pairing).',
    )
    parser.add_argument(
        '--ready-file',
        help='File to create once org.bluez is claimed and answering. Lets a '
             'caller wait on a fact instead of on a sleep.',
    )
    parser.add_argument(
        '--seconds', type=float, default=0,
        help='Exit after this many seconds. 0 (the default) runs until killed.',
    )
    args = parser.parse_args()

    if not os.environ.get('DBUS_SYSTEM_BUS_ADDRESS'):
        sys.stderr.write(
            'DBUS_SYSTEM_BUS_ADDRESS is not set. Refusing to run: without it '
            'this would try to claim org.bluez on the real system bus.\n'
            'Use scripts/linux-virtual-ble.sh, which starts a private bus.\n'
        )
        return 2

    scenario = DEFAULT_SCENARIO
    if args.scenario:
        with open(args.scenario) as handle:
            scenario = json.load(handle)

    logging.getLogger().addFilter(_DeliberateRefusalFilter())

    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    stack = VirtualStack(bus, scenario)
    stack.export_adapter()
    await bus.request_name('org.bluez')

    if args.ready_file:
        with open(args.ready_file, 'w') as handle:
            handle.write(os.environ['DBUS_SYSTEM_BUS_ADDRESS'])

    names = ', '.join(d['name'] for d in scenario)
    print(f'virtual org.bluez up on {ADAPTER_PATH} with: {names}', flush=True)

    if args.seconds:
        await asyncio.sleep(args.seconds)
    else:
        await bus.wait_for_disconnect()
    return 0


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
