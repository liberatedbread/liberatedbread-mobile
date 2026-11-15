# Weber iGrill Bluetooth Thermometers

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Weber-Stephen Products (formerly iDevices)
> **Manufacturer Status**: Unsupported (Weber's own statement ends security support in 2021, but the app was still updated in 2025)

## Overview

The iGrill family is a set of Bluetooth LE cooking thermometers. iDevices
designed them and Weber sold them after buying iDevices' grilling line. One
app, **Weber iGrill** (`com.weber.igrill`), drives the whole family:

| Model | Probes | Power | Notes |
|---|---|---|---|
| iGrill mini | 1 | CR2032 | Smart LED ring |
| iGrill mini v2 | 1 | coin cell | later mini revision |
| iGrill 2 | 4 | 2x AA | display, probe toggle buttons |
| iGrill 2 v2.2 | 4 | 2x AA | later iGrill 2 revision (the community calls it "v202") |
| iGrill 3 | 4 | 3x AA pack | mounted on Genesis II / LX gas grills, propane gauge, knob lights |
| Kitchen Thermometer | 2 | 2x AA | originally the iDevices Kitchen Thermometer |
| Kitchen Thermometer Mini | 1 | coin cell | originally the iDevices Kitchen Thermometer mini |
| Pulse 1000 (built-in iGrill) | 2 | mains | electric grill; only the thermometer is covered |
| Pulse 2000 (built-in iGrill) | 4 | mains | electric grill; only the thermometer is covered |

The protocol is fully local. The phone bonds with the thermometer, runs a
short AES challenge-response, and then reads and subscribes to the probe
characteristics. Weber's Firebase cloud only syncs accounts, recipes and cook
history. The protocol is worth writing down for two reasons. Weber's own 2024
UK PSTI statement lists the end of security updates for every model as 2021.
And the app has already dropped the original iGrill Classic.

**Out of scope:**

- the Pulse grills' heater and controller service
  (`6c910000-58dc-41c7-943f-518b278ceaaa`). It heats, so it is
  safety-sensitive, and none of its control is documented.
- firmware-update payloads and flashing byte sequences (the mechanism is
  described by role only)
- the original iGrill Classic, the Wi-Fi Weber Connect / SmokeFire products,
  and the Firebase account cloud

Nothing here has been driven against hardware by this project, and our
research store holds no capture of any model. Every byte layout is
**reported**. It comes from static analysis of the vendor app (5.8.1),
cross-checked against community clients that do run on hardware
(bendikwa/esphome-igrill and 1mckenna/esp32_iGrill).

## Hardware

| Property | Value |
|----------|-------|
| Models | See the table above. The app identifies each model by its advertised name. |
| Chipset | BLE radio: an 8051-core SoC, consistent with the TI CC254x family. This is inferred from the format of the vendor's update images and is not confirmed. The Pulse controller is an ARM Cortex-M (STM32-class) MCU. |
| Radio | Bluetooth LE ("Bluetooth Smart" / 4.0 in the manuals). The Pulse manual gives 2402-2480 MHz at 1 mW. |
| FCC ID | None found. No manual prints one, and fccid.co has no iGrill grant under iDevices (2ABDJ) or Weber-Stephen (2AHSR). |
| BLE address | Public, in Weber-Stephen's IEEE block `70:91:8F` |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. Nothing is provisioned. Every connection needs a bond plus the handshake. |
| Method | `ble_direct` (bond, then the key-free challenge handshake) |
| Setup AP / advertised name | Advertised names start with a model prefix that the app matches case-insensitively (`igrill_mini`, `igrill_v2`, `igrill_v3`, `kt`, `pulse 1000`, ...). Only `iGrill_mini` is on record verbatim. Labels like `iGrill2-XXXX` are the app's display names, not advertised names. |
| Passphrase protection | not_applicable |
| Confidence | medium (two working open implementations; not replayed here) |

Connect and run the handshake like this:

1. Power the unit on. The Bluetooth LED (the Smart LED ring on the mini
   models) blinks blue while it waits to pair. Close the vendor app first:
   the unit accepts only one connection.
2. Connect and bond (Just Works, no passkey). On a phone, accept the OS
   pairing request.
3. Write 16 zero bytes to `64ac0002-4a4b-4b58-9f37-94d3c52ffdf7`.
4. Read 16 bytes from `64ac0003-4a4b-4b58-9f37-94d3c52ffdf7`.
5. Write those same 16 bytes to `64ac0004-4a4b-4b58-9f37-94d3c52ffdf7`.
6. Read `06ef0001-2e06-4b79-9e33-fce2c42805ec`. Byte 0 is the unit
   (0 = °F, 1 = °C).
7. Subscribe to the probe characteristics.

The vendor app gives steps 3-5 30 seconds. It also bonds before connecting,
polling the bond state every 500 ms for up to 30 s.

**Factory reset**: the vendor manuals describe a reset only as the fix for a
pairing that won't take. Every one of them says to forget or unpair the
device in the phone's Bluetooth settings first.

| Models | Procedure | Confirmation |
|---|---|---|
| iGrill mini, mini v2, Kitchen Thermometer Mini | Unit powered on, lifted off its base: remove the battery door and hold the pin-hole reset button about 5 s | Light ring turns solid white |
| iGrill 2, iGrill 2 v2.2, Kitchen Thermometer | Unit powered on: remove the battery door and hold the reset button with a pin (or a probe tip) for 5 s | Display runs its power-on animation |
| iGrill 3 | Unit powered on: hold the power button on the faceplate for 15 s | not stated |
| Pulse 1000 / 2000 | No reset documented. The manual says to turn off Bluetooth on the phone that holds the connection. | Bluetooth light flashes again |

The reset clears the stored Bluetooth pairing. Whether it also clears the
unit setting and the stored alarm thresholds is not documented. None of these
procedures has been run by this project.

**Rebinding to a new network**: there is no network. To move a unit to a new
phone or client, disconnect the old one (close its app, turn its Bluetooth
off) and pair the new one. If the unit refuses, forget it on the old phone
and reset it.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes. Community clients report that the probes cannot be read without link encryption and a bond. |
| Security mode | `just_works` for the link, plus an application-layer AES challenge on every connection |
| Bonding | `required` |
| PIN source | none (Just Works) |
| One central at a time | Yes (esphome-igrill README; Pulse manual) |
| One bond at a time | Unknown |
| Confidence | medium (open implementations and manuals) |

**Entering pairing mode**: not needed. An unconnected unit that is powered on
is discoverable. The blue LED blinks while it waits, and turns solid once
paired.

**Unpairing**: no bond-only clear is documented. The manuals' route is to
forget the device on the phone and use the reset above.

**Recovery**: close the vendor app, and turn Bluetooth off on any phone that
used the unit. If that isn't enough, forget the unit in the phone's Bluetooth
settings and reset it.

### The handshake, and why no key is needed

The app writes a 16-byte challenge (8 random bytes, then 8 zeros). The device
answers on `64ac0003-…` with AES-128-ECB(K, the challenge's first 8 bytes ‖ an
8-byte device nonce). The app decrypts that, zeroes the first 8 bytes,
re-encrypts, and writes the result to `64ac0004-…`. The app's cipher setup
fixes the mode as AES/ECB with no padding. K is a 16-byte constant per model
family, held in the vendor app. **The keys are deliberately not published
here.**

A client does not need them. With an all-zero challenge, the decrypted first
half is already zero, so the correct response is simply the 16 bytes the
device sent. kins-dev/igrill-smoker worked this out, and bendikwa/igrill,
esphome-igrill and esp32_iGrill all use it. The spec's
`protocol_details.authentication.test_vectors` check both forms of the
arithmetic under the FIPS-197 example key (not a device key).

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `64ac0000-4a4b-4b58-9f37-94d3c52ffdf7` | Authentication / update | `…0001` firmware version (UTF-8), `…0002` app challenge, `…0003` device challenge, `…0004` device response, `…0005` update control point (never write it) |
| per-model service (below) | Thermometer | configuration, probe temperatures, alarm pairs, ambient |
| `f5d40000-3548-4c22-9947-f3673fce3cd9` | Propane level (iGrill 3) | `f5d40001-…` quarter-tank steps |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery | `00002a19-0000-1000-8000-00805f9b34fb`, percent |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | model number, manufacturer, hardware revision, serial number (per unit, do not publish) |

Every model serves the **same thermometer characteristics** (base
`06efxxxx-2e06-4b79-9e33-fce2c42805ec`) under its **own** primary service.
The vendor app finds characteristics by UUID alone, so a client can too. The
model service is how you tell models apart:

| Model | Thermometer service | Source |
|---|---|---|
| iGrill mini | `63c70000-4a82-4261-95ff-92cf32477861` | esphome-igrill, esp32_iGrill |
| iGrill mini v2 | `9d610c43-ae1d-41a9-9b09-3c7ecd5c6035` | esphome-igrill, esp32_iGrill (the app's table files it under "mini") |
| iGrill 2 | `a5c50000-f186-4bd6-97f2-7ebacba0d708` | esphome-igrill, esp32_iGrill |
| iGrill 2 v2.2 | `ada7590f-2e6d-469e-8f7b-1822b386a5e9` | esphome-igrill, esp32_iGrill (the app's table files it under "iGrill 2") |
| iGrill 3 | `6e910000-58dc-41c7-943f-518b278cea88` | app, esphome-igrill, esp32_iGrill |
| Kitchen Thermometer | `19450000-9b05-40bb-80d8-7c85840aec34` | app, esphome-igrill |
| Kitchen Thermometer Mini | `38e70000-43bf-4afa-8170-e45548b5205b` | app only |
| Pulse 1000 | `7e920000-68dc-41c7-943f-518b278cea87` | esphome-igrill |
| Pulse 2000 | `7e920000-68dc-41c7-943f-518b278cea88` | esphome-igrill |

The thermometer characteristics:

| UUID | Properties | Role |
|---|---|---|
| `06ef0001-2e06-4b79-9e33-fce2c42805ec` | read, write | 5-byte configuration: [0] unit (0 = °F, 1 = °C), [2] alarm acknowledged, [1], [3-4] unknown |
| `06ef0002-2e06-4b79-9e33-fce2c42805ec` | read, notify | Probe 1 temperature |
| `06ef0003-2e06-4b79-9e33-fce2c42805ec` | read, write | Probe 1 alarm pair |
| `06ef0004-…` / `06ef0006-…` / `06ef0008-…` | read, notify | Probes 2, 3, 4 temperature |
| `06ef0005-…` / `06ef0007-…` / `06ef0009-…` | read, write | Probes 2, 3, 4 alarm pairs |
| `06ef000a-2e06-4b79-9e33-fce2c42805ec` | read, notify | Ambient temperature (which models serve it is unknown) |
| `06ef000b-2e06-4b79-9e33-fce2c42805ec` | read, write | Ambient alarm pair (earlier notes listed this role as unknown) |

### Temperature notification

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | int16 little-endian, **whole degrees** in the configured unit. Below -500 means no probe, and the device sends -2000 (`30 f8`). |
| 2 | 1 | bit 7 = this sample's unit (0 = °F, 1 = °C) |

Example: `a5 00 80` is 165 °C. `30 f8 00` is "no probe". Clients that read the
field unsigned see 63536 instead.

### Alarm pair (write with response)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | low alarm, int16 LE, whole degrees; -2000 = off |
| 2 | 2 | high alarm (the target), int16 LE, whole degrees; -2000 = off |

The app's **peak** alarm writes only the high side (`30 f8 <hi> <hi>`). Its
**range** alarm writes both. Ending a cook writes `30 f8 30 f8`. The device
keeps these values and acts on them itself: the manuals describe the unit's
tone and LED colours stepping toward the target, and esphome-igrill verified
the write format against a capture of the vendor app. Example: a 203 °F
peak target on probe 1 is `30 f8 cb 00`, written to `06ef0003-…`.

### Configuration and units

The app reads `06ef0001-…` on every connection and writes it back with byte 2
set to 0. It writes byte 2 = 1 when the user dismisses an alarm. When the user
changes the unit, the app rewrites the block with the new byte 0, converts
every stored threshold, and rewrites all the alarm pairs. **The device does
not convert thresholds itself.** esp32_iGrill sets the unit with a single-byte
write instead. Whether that write keeps bytes 1-4 intact is not established.

### Propane (iGrill 3)

`f5d40001-3548-4c22-9947-f3673fce3cd9`: bytes 0-1 are a uint16 LE from 0 to 4,
meaning 0, 25, 50, 75 or 100 %. A higher value, or bit 0 of byte 2, marks a
sensor fault.

### Firmware update (role only)

The app fetches images from a vendor object store and has three update
paths. The first is an update-begin command on `64ac0005-…` followed by
blocks written to `00060001-f8ce-11e4-abf4-0002a5d5c51b`, paced by
notifications. The second is Intel-HEX records written to `64ac0005-…`
itself. The third, on the Pulse grills only, sends checksummed packets to the
controller service. No payload, layout, offset or image is published: a wrong
write can leave a thermometer unusable.

## Troubleshooting

These come from the manuals, the vendor app's own connection handling, and
store reviews of the vendor app.

- **The handshake succeeds but the probes return nothing.** The link isn't
  encrypted. Bond first. The handshake runs on every connection, not once
  per bond.
- **Won't connect, or times out.** Another phone, or the vendor app running
  in the background, holds the single connection. Turn off that phone's
  Bluetooth. An unpaired unit also powers itself off: after 5 minutes with no
  probe, and after 8 hours with a probe fitted.
- **Android pairing loops, or "paired but not connected".** A stale bond.
  The manuals' fix is to unpair in Bluetooth settings, restart Bluetooth, and
  reset the unit. The vendor app itself removes and remakes the bond when the
  handshake fails, and retries on GATT status 129. It also carries workarounds
  for specific older LG, Motorola and Nexus phones and for Samsung devices.
  Reviews from 2019-2024 report Samsung phones that never pair.
- **After walking out of range, the vendor app won't reconnect until the
  unit is reset and paired again.** This is a vendor-app defect reported
  repeatedly between 2020 and 2024. A replacement client should reconnect on
  the existing bond and rerun the handshake.
- **Readings or alarms off by the °F/°C ratio.** The unit was assumed. Read
  byte 0 of `06ef0001-…`, or bit 7 of each sample's byte 2, and convert the
  stored thresholds whenever the unit changes.
- **A probe reads 63536 or -2000.** It is unplugged.

## Tools Used

- [x] Static analysis of the vendor Android app (Weber iGrill 5.8.1), for
  roles, UUIDs and byte layouts only
- [x] Community clients: bendikwa/esphome-igrill, 1mckenna/esp32_iGrill,
  bendikwa/igrill, kins-dev/igrill-smoker, kvantetore/igrill
- [x] Vendor manuals (Weber-hosted and archived iDevices editions) and Weber's
  PSTI statement
- [ ] nRF Connect / btsnoop capture against a real unit: **still needed**.
  The first things to capture are the exact advertised names, the keyed
  handshake, and an alarm acknowledgement.

## References

- [Weber iGrill Mini user manual (2016, PDF)](https://digital-assets.weber.com/documents/59338.pdf?fm=pdf)
- [Weber iGrill 2 user manual (2016, PDF)](https://digital-assets.weber.com/documents/59365.pdf?fm=pdf)
- [Weber iGrill 3 user manual (2016, PDF)](https://digital-assets.weber.com/documents/59392.pdf?fm=pdf)
- [Weber Pulse 2000 owner's guide (US, 2022, PDF)](https://digital-assets.weber.com/documents/54975_022522.pdf?fm=pdf)
- [Weber Pulse 1000 / 2000 owner's guide (GB, 2018, PDF)](https://digital-assets.weber.com/documents/59587_100118_web.pdf?fm=pdf)
- [iDevices Kitchen Thermometer user manual (Internet Archive)](https://archive.org/download/manualzilla-id-5673305/5673305.pdf)
- [iDevices Kitchen Thermometer mini user manual (Internet Archive)](https://archive.org/download/manualzilla-id-5815436/5815436.pdf)
- [Weber UK PSTI statement for iGrill thermometers (2024, PDF)](https://digital-assets.weber.com/documents/18492_8653986_042524.pdf?fm=pdf)
- [bendikwa/esphome-igrill](https://github.com/bendikwa/esphome-igrill)
- [1mckenna/esp32_iGrill](https://github.com/1mckenna/esp32_iGrill)
- [bendikwa/igrill: igrill.py](https://github.com/bendikwa/igrill/blob/e42dba408bc59a2f4ee36546ee92e9e7135ba8d6/igrill.py)
- [kins-dev/igrill-smoker: igrill.py](https://github.com/kins-dev/igrill-smoker/blob/5dc78b5f2ce323c9aa2145e2b74d1e49c60d20c4/scripts/pygrill/bluetooth/igrill.py)
- [kvantetore/igrill](https://github.com/kvantetore/igrill)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update](../protocols/firmware-update.md)

## Contributors

- Claude Code agent: spec written from the vendor app's static analysis, community clients and manuals (desk research; no hardware)
