# CHEMION LED Glasses / CHEMION HAT

> **Status**: In Progress
> **Protocol**: BLE
> **Manufacturer**: CHEMION (CoolLED OEM hardware; companion app by Neofect)
> **Manufacturer Status**: Unsupported

## Overview

CHEMION glasses are sunglasses with a 9×24 LED matrix across the front; the CHEMION
HAT is a cap with a 12×32 colour LED matrix. Both are driven from the CHEMION phone app
(Android package `com.neofect.chemion`), which doubles as a design tool and a storefront
for downloadable content packs. The store and login live in the vendor cloud — **the
control protocol does not**. Everything the app does to the device is one BLE frame
protocol, fully mapped here from the app (v3.0.5) and cross-checked against public 2015
reverse engineering ([gsuberland/ChemionHacking](https://github.com/gsuberland/ChemionHacking)).
That earlier work left the packet checksum unsolved; it is a plain XOR over the payload
bytes.

A replacement app can scan, connect, stream frames, upload designs to device slots and
read battery without any vendor service.

## Hardware

| Property | Value |
|----------|-------|
| Models | CHEMION Original (glasses), CHEMION HAT (cap) |
| Chipset | Nordic nRF51 series (glasses; per public teardown) |
| Radio | BLE (Nordic UART Service on the glasses) |
| Glasses matrix | 9 rows × 24 cols, 2 bits per pixel, 54-byte frames |
| HAT matrix | 12 × 32, 4 bits per pixel color, 1536-byte frames |
| Save slots | ~6 (glasses) / ~144 (HAT) — inferred from app constants, unverified |

## Initial Setup

No provisioning. Power the device on; it advertises immediately and accepts a
connection from any central — no account, PIN or bonding step exists in the app flow.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised name | prefix `CHEMION` (glasses), `HAT` (cap); some units show `CoolLED` |
| Passphrase protection | not_applicable |
| Confidence | medium (from the app's connect flow; not yet replayed on hardware) |

After connecting, enable notifications on the notify characteristic and send the
heartbeat frame every 5 seconds — the app does this per connected device, and whether
the link survives without it is untested.

**Factory reset**: none documented and none found in the app — there is no credential
state to clear. Power-cycling drops the current connection, which is the remedy for
the usual failure mode: the device is still connected to another phone (one BLE link
at a time).

**Rebinding to a new controller**: just connect from the new one — nothing binds the
device to an owner. If the old phone keeps grabbing the link, remove the device from
its OS Bluetooth list so a cached bond stops auto-reconnecting.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART (glasses) | Primary service, CHEMION Original |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | Command Write | Frames written here, one write per frame |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | Notify | Replies/notifications (layout unverified) |
| `4b0d67ea-2faf-4b3c-8c53-f6af0f0171f5` | HAT service | Primary service, CHEMION HAT |
| `4b0d67eb-2faf-4b3c-8c53-f6af0f0171f5` | Command Write | HAT frames (roles by convention, verify) |
| `4b0d67ec-2faf-4b3c-8c53-f6af0f0171f5` | Notify | HAT replies (roles by convention, verify) |

### Frame format

Every command is one frame, written in a single characteristic write:

```
[0xFA] [cmd] [lenHi] [lenLo] [payload …] [checksum] [0x55] [0xA9]
```

- `cmd` is the command **type**: `0x01` request, `0x02` reply, `0x03` stream,
  `0x04` notify, `0x05` error, `0x06` identify.
- `lenHi/lenLo` = payload length, big-endian.
- `checksum` = **XOR of the payload bytes only** (header, cmd and length excluded).
- Payloads embed a 2-byte big-endian message ID plus, almost always, a constant `0x01`.

Worked example — power off: `FA 01 00 03 00 02 01 03 55 A9`
(payload `00 02 01`, checksum `00^02^01 = 03`).

### Commands

| Message ID | Type | Payload | Description |
|-----------|------|---------|-------------|
| 2 | request | `00 02 01` | Power off |
| 3 | request | `01 00 03` | Battery level query (reply on notify char) |
| 5 | request | `01 00 05` | Heartbeat — send every 5 s |
| 6 | stream | `01 00 06 <data>` | Realtime frame streaming (glasses path) |
| 7 | request | `01 00 07` | Slot/status query (semantics unverified) |
| 9 | notify | `01 00 09` | Sound-reactive streaming marker |
| 10 | request | `01 00 0A <data>` | Frame data block (54 B glasses / 1536 B HAT) |
| 11 | request | `01 00 0B <slot> <sizeHi> <sizeLo>` | Transfer start (glasses; HAT sends empty payload) |
| 12 | request | `01 00 0C` | Transfer end (glasses) |
| 13 | request | `01 00 0D 01 [data]` | Play stored frames (glasses) |
| 14 | request | `01 00 0E <slot>` | Slot op — play/delete family (glasses) |
| 16 | request | `01 00 10 <slot>` | Slot op — free/delete family |
| 20 | request | `01 00 14 <slot>` | Slot-frame upload start (both types) |
| 21 | request | `01 00 15` | Slot-frame upload end (glasses) |

Message ID 4 emits the same wire bytes as 16 (legacy alias). Three further IDs are
loaded from values the static analysis could not resolve (likely 1, 8 and 15 or 17 —
status, old heartbeat, delete/DFU family per the 2015 wiki).

Full byte-level frames, parameters and confidence notes are in the machine-readable
spec: `device-specs/devices/chemion-glasses.yaml`.

### Discovery

| Signal | Meaning |
|--------|---------|
| Name prefix `CHEMION` | CHEMION Original glasses — NUS service |
| Name prefix `HAT` | CHEMION HAT |
| Name contains `CoolLED` | OEM-branded unit of the same family |
| Service `6e400001-…` | Glasses protocol endpoint |
| Service `4b0d67ea-…` | HAT protocol endpoint |

### Cloud (not needed for control)

`api.chemi-on.com` and `content.chemi-on.com` serve the content store (fonts and
sound packs as ZIP) and login/SNS features. No command travels through them.

## Open Questions

- Notify-channel reply layout (battery level, error frames) — parsing was not fully
  traced; verify with one HCI capture.
- Which messages open/close a slot upload in practice (11/12 vs 20/21), and where
  frame counts and timing ride.
- Pixel encodings: 2 bpp bit order on the glasses; 4 bpp nibble order/palette on the HAT.
- Whether the 5 s heartbeat is mandatory to hold the link.
- HAT realtime-streaming route (its msgId-6 path emits an empty payload in the app).
- OTA: app v3.0.5 has no DFU path; the 2015 app had nRF legacy DFU, so old bootloaders
  may accept firmware — unexplored and not needed for control.

## Tools Used

- [x] APK static analysis (Dart AOT disassembly of the Flutter app)
- [x] Public prior reverse engineering (ChemionHacking wiki)
- [ ] HCI snoop of connect / battery / upload (pending — highest priority)

## References

- [gsuberland/ChemionHacking — 2015-era protocol reverse engineering](https://github.com/gsuberland/ChemionHacking)
- [CHEMION app on Google Play](https://play.google.com/store/apps/details?id=com.neofect.chemion)
- [CHEMION official site](https://www.chemionglasses.com/)

## Contributors

- @gsuberland — original 2015 CHEMION protocol reverse engineering
