#!/usr/bin/env python3
"""Probe a nearby Govee BLE device: dump its advertisement and read the
standard identification/sensor characteristics.

Verification scaffolding for the govee-* device specs — not a client.

Usage:
    python3 scripts/govee_ble_probe.py [MAC]

Pass the address of the unit in front of you; the default is a
placeholder in the Telink OUI (A4:C1:38) that will not match anything.
Requires: bleak (pip install bleak), a BlueZ adapter, and the device
advertising (kill any app holding its connection first).
"""

import asyncio
import sys

from bleak import BleakClient, BleakScanner

TARGET = sys.argv[1] if len(sys.argv) > 1 else "A4:C1:38:AA:BB:CC"

READS = [
    ("00002a29-0000-1000-8000-00805f9b34fb", "ManufacturerName"),
    ("00002a24-0000-1000-8000-00805f9b34fb", "ModelNumber"),
    ("00002a25-0000-1000-8000-00805f9b34fb", "SerialNumber"),
    ("00002a26-0000-1000-8000-00805f9b34fb", "FirmwareRev"),
    ("00002a27-0000-1000-8000-00805f9b34fb", "HardwareRev"),
    ("00002a28-0000-1000-8000-00805f9b34fb", "SoftwareRev"),
    ("00002a00-0000-1000-8000-00805f9b34fb", "DeviceName"),
    ("00002a19-0000-1000-8000-00805f9b34fb", "Battery_pct"),
    ("00002a6e-0000-1000-8000-00805f9b34fb", "Temperature_2a6e"),
    ("00002a6f-0000-1000-8000-00805f9b34fb", "Humidity_2a6f"),
    ("00002a1f-0000-1000-8000-00805f9b34fb", "TempCelsius_2a1f"),
    ("00001f1f-0000-1000-8000-00805f9b34fb", "Vendor_1f1f"),
]


async def main() -> None:
    found = {}

    def cb(dev, adv):
        if dev.address.upper() == TARGET.upper() and not found:
            found["dev"] = dev
            found["adv"] = adv

    print(f"scanning for {TARGET} (45s)...")
    async with BleakScanner(detection_callback=cb):
        for _ in range(45):
            if found:
                break
            await asyncio.sleep(1)

    if not found:
        print("not found — kill any app connected to it (or power-cycle it) and retry")
        return

    adv = found["adv"]
    print(f"name={adv.local_name!r} rssi={adv.rssi}")
    print(f"service_uuids={adv.service_uuids}")
    for cid, data in (adv.manufacturer_data or {}).items():
        print(f"mfg 0x{cid:04x}: {data.hex()}")
    for uuid, data in (adv.service_data or {}).items():
        print(f"svcdata {uuid}: {data.hex()}")

    async with BleakClient(found["dev"], timeout=30) as client:
        print(f"connected, mtu {client.mtu_size}")
        for uuid, label in READS:
            try:
                value = await client.read_gatt_char(uuid)
                text = value.decode(errors="replace") if any(32 <= b < 127 for b in value) else ""
                print(f"{label}: {value.hex()}  {text!r}")
            except Exception as exc:  # noqa: BLE001 — report any GATT error and continue
                print(f"{label}: <{type(exc).__name__}>")


if __name__ == "__main__":
    asyncio.run(main())
