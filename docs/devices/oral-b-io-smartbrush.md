# Oral-B iO Smart Brush and iO Sense Charger

> **Status**: Spec Available (app/capture-derived; untested on hardware here)
> **Protocol**: BLE GATT and manufacturer advertisements
> **Manufacturer**: Procter & Gamble
> **Manufacturer Status**: Active

## Overview

The iO brush and iO Sense charger expose local BLE state and control surfaces
without requiring the Oral-B cloud for basic reads. Brush UUIDs use
`a0f0xxxx-5047-4d53-8208-4f72616c2d42`. Protocol versions V001–V009 change
layouts, so read the version before decoding version-dependent fields.

The November 2026 follow-up adds an independently captured iO Series 10 / iO
Sense implementation. It establishes the charger service `a0f03e00-…`, its
read-only native and brush-passthrough grammar, charger status bits, extended
battery records and retained-session summaries. Its 488 tests passed upstream;
this project did not connect to a brush or charger.

## Setup and Pairing

The brush needs no account or provisioning. Discovery uses manufacturer data
under P&G company ID `0x00DC` (wire bytes `dc 00`), not a service-UUID scan.
The brush filter needs only five bytes but the complete brush advertisement is
15 bytes. The charger filter accepts a shorter packet, but decode its complete
layout only with all 18 full-packet bytes.

The brush accepts one BLE client. The charger forwards brush reads only while
it owns that connection. The charger is an outbound network client, not an
inbound HTTP/HTTPS/SSH/MQTT management API. Wi-Fi provisioning credential
sequencing and the durable upload queue remain undocumented.

No application-level bond is required by the documented paths. Reconnect after
the previous client releases the brush.

### Reset and rebinding

The YAML distinguishes three operations:

- Handle reset: hold the power button until the LED flashes. Published hold
  times vary, so follow the indicator rather than assuming an exact duration.
- Display-model reset: use the handle's Settings/factory-reset menu; the same
  menu can simply disable Bluetooth.
- iO Sense charger reset: touch and hold its button until an orange light
  appears, release, then tap once more while the light is showing.

These are not the same operation and do not clear identical state. Moving a
client normally needs only a disconnect/reconnect, not a factory reset.

## Core GATT services

| Service | Role |
|---|---|
| `a0f0ff00-5047-4d53-8208-4f72616c2d42` | Brush characteristics and OTA path |
| `a0f03e00-5047-4d53-8208-4f72616c2d42` | iO Sense charger commands, payload, returned data and status |

The charger characteristics were previously grouped under the brush service;
that was incorrect. Their actual roles are:

| Characteristic | Role |
|---|---|
| `a0f03c00-…` | Command header and final delimiter, write |
| `a0f03c01-…` | Returned data, read/notify |
| `a0f03c02-…` | Command payload, write |
| `a0f03c03-…` | Command status, read/notify |

Protocol-2 headers are `[operation, command]`: GET `c0`, POST `c1`, EXECUTE
`c2`. Finish every transaction with `e0` on C00 and validate C03 status
`[command, operation, result]`, where `01` was observed for success.

A passthrough brush read is:

```text
C00: c1 37
C02: uuid_lsb uuid_msb 01 00
C00: e0
```

For example, `08 ff 01 00` reads FF08. Successful status is `37 c1 01`; returned
data is `37 c1 uuid_lsb uuid_msb operation success length data…`. Serialize one
complete transaction at a time—the tested charger rejects batched records.
Native read-only command IDs include device info, Wi-Fi/IoT state, firmware,
uptime, clock, brush/passthrough state, ring and night-light state. The YAML
lists all 24 IDs without granting POST/EXECUTE permission.

## Battery record FF05

The older one-byte percentage remains valid. Later records are little-endian
and length-gated:

| Offset | Field | Rule |
|---:|---|---|
| 0 | Battery percentage | uint8 |
| 1–2 | Estimated brushing seconds remaining | uint16; `0xffff` unavailable; zero unavailable only on protocol 6 |
| 3–4 | Millivolts | uint16, protocol 8+ |
| 5–6 | Signed milliamps | int16, protocol 8+; `-1` unavailable |
| 7 | Temperature | int8 °C, protocol 8+ |

Do not decode absent fields from shorter packets. The spec binds percentage,
runtime, voltage, current and temperature entities only with those version and
sentinel rules.

## Retained session FF29

Protocol 7/8 uses a 21-byte little-endian retained-session record. Protocol 9
is registered for compatibility in the public implementation; protocol 6 has a
different 20-byte layout and must not use this table.

| Offset | Meaning |
|---:|---|
| 0–3 | Brush-clock start; not automatically a Unix timestamp |
| 4–5 | Packed session ID (`& 0x1fff`) and user ID (`>> 13`) |
| 6–7 | Packed target seconds (`& 0x1fff`) and sector count (`>> 13`) |
| 8–9 | Duration in seconds |
| 10–13 | High/low-pressure durations, each uint16 × 0.1 seconds |
| 14 | Average pressure, uint8 × 100 mN |
| 15 | Maximum pressure, uint8 × 100 mN |
| 16–17 | High/low-pressure event counts |
| 18 | Power-on count |
| 19 | Mode, decoded by packet protocol version |
| 20 | Ending battery percent when ≤ 100 |

The captured direct client reads the latest record after session settlement
without an FF21 command. Charger reads have a separate availability window.

## Advertisements and diagnostics

The complete brush advertisement has 15 bytes: protocol/model/software, state,
button/pressure flags, timer, mode, progress and quadrant data. It has **no
battery byte**; battery comes from FF05.

The iO Sense manufacturer value is 14 bytes starting at full-packet offset 4.
It carries protocol, charger type `0xa2`, software version, server mode, an
advertised MAC, body color and a final status byte. Redact the MAC in fixtures.
Status bits are:

0 Wi-Fi, 1 internet, 2 cloud, 3 brush connected, 4 brush charging, 5 touchpad
active, 6 brush paired, 7 demo mode. Advertisements do not carry timer,
pressure, zone, score or completed-session data.

### ServiceDataA/B

These are 16-byte **GATT diagnostics**, not advertisements. All fields are
little-endian.

- **ServiceDataA:** uint16 ideal full capacity and average motor current, then
  uint32 total motor-runtime, pressure-time and charge-time seconds. Capacity
  and current units are unresolved.
- **ServiceDataB:** eight uint16 fields: charge events, full-charge events,
  over/low-temperature events, brushing cycles, short-term motor current,
  recharge events and recharge hours. Current units are unresolved.

### SonosMetadata

SonosMetadata is 14 bytes through V007 and 30 bytes from V008. It starts with
`0xff`, then model (M4=6, M5=5, M6=4, M7=3, M8=2, M9=1, M10=16), color,
language, eight mode values, position-resolution byte and GumGuard
(0 off, 1 on, 2 HD, 255 unavailable). V008 adds a 16-byte statistics block with
`0xfe` separating default/available screens and `0xff` as end marker. The YAML
declares all ten screen IDs.

## Remaining gaps and validation

Wi-Fi provisioning writes, charger upload-queue enumeration, firmware-container
decryption, protocol-6 FF29, current/capacity units and the second drive-target
word remain unresolved. No provisioning or speculative POST/EXECUTE operation
is declared.

`scripts/test_oral_b_io_smartbrush_spec.py` verifies the corrected service map,
extended battery decoding, packed session fields, charger status bits,
diagnostic widths and the passthrough sequence.

See `device-specs/devices/oral-b-io-smartbrush.yaml` for the complete GATT map,
version-specific layouts, OTA boundary and reset procedures.

## References

- [thomasgregg/oralb-ha — captured iO Sense protocol](https://github.com/thomasgregg/oralb-ha), pinned at `c0910404ab3f4dffffcf6c3eb994a030d63f7306`
- [MatrixEditor/oralb-io](https://github.com/MatrixEditor/oralb-io)
- [Bluetooth-Devices/oralb-ble](https://github.com/Bluetooth-Devices/oralb-ble)
- [Home Assistant Oral-B integration](https://www.home-assistant.io/integrations/oralb)
- [Oral-B iO Series 9 manual](https://m.media-amazon.com/images/I/81LQHI5cS6L.pdf)
