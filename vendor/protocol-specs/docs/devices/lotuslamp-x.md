# LotusLamp X LED Controllers

> **Status**: Complete (GATT control path); mesh/encrypted variants in progress
> **Protocol**: BLE
> **Manufacturer**: Shenzhen ELK
> **Manufacturer Status**: Unsupported

## Overview

LotusLamp X (`com.szelk.ledlamppro`) is the design app for a family of cheap,
widely-rebadged BLE LED strip and lamp controllers from Shenzhen ELK, sold under
advertised names starting with `ELK-`, `MELK-`, `ELBU-` and a long list of OEM
variants (`HX6-`, `HCW-`, `BYC-`, `SHY-`, `MHRS-`, `THUNDEROBOT`, "LED LIGHT
STRIP", "LED Constellation Lights", …). They are addressable-RGB controllers:
color, brightness, speed and 213 built-in animations, plus timers, microphone
rhythm and (on some models) mesh groups.

The good news: the devices are fully local. The app speaks BLE only — no Wi-Fi,
no account — and the core protocol is independently reverse engineered and
live-tested by the [lotus-lamp](https://pypi.org/project/lotus-lamp/) Python
library, so these lamps will keep working long after the app is gone.

!!! note "Privacy"
    The vendor app uploads device stats/telemetry to `lotus.elkled.com:8082`
    (and self-updates from `elkble.com`). The lamp itself never uses the
    network — a local BLE client gives you everything the hardware can do
    without the telemetry.

## Hardware

| Property | Value |
|----------|-------|
| Model numbers | ELK-/MELK-/ELBU- prefixed (reference unit: MELK-OA10) |
| Chipset | Unknown (generic low-cost BLE SoC; chip-agnostic from the app side) |
| Radio | BLE |
| FCC ID | |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `ELK-*`, `MELK-*`, `ELBU-*` or OEM variant |
| Passphrase protection | not_applicable |
| Confidence | medium (static analysis + public, live-tested RE library) |

Power the lamp and it advertises immediately. Scan for the `0xFFF0` service
UUID (or one of the name prefixes above), connect, and write command frames to
characteristic `0xFFF3`. There is no pairing, PIN or account. Subscribe to
`0xFFF4` if you want state notifications.

**Factory reset**: no credential state exists, so there is nothing to clear.
The app exposes a restore-factory opcode (`0x87`) but its frame and effect are
unverified. The practical remedy for "can't connect" is a power cycle — the
lamp accepts only one BLE connection at a time, and if the previous phone is
still hanging onto it, remove the device from that phone's OS Bluetooth list
so it stops auto-reconnecting.

**Rebinding to a new controller**: in place. Nothing ties the lamp to an owner;
connect from the new client after disconnecting the old one.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Control Service | Primary (and only custom) service |
| `0000fff3-0000-1000-8000-00805f9b34fb` | Command Write | All commands, write-without-response |
| `0000fff4-0000-1000-8000-00805f9b34fb` | State Notify | Status echoes (payload layout not fully mapped) |

The app also reads the standard Device Information characteristics and Battery
Level on connect.

### Commands — E1 frame family

All commands are 9-byte frames: `7E <len> <cmd> <p0..p4> EF`. Unused parameters
pad with `0xFF`. The `<len>` byte is not strictly validated by the firmware —
emit the values below, but a mismatch is not fatal.

| Command | Frame | Description |
|---------|-------|-------------|
| Power on | `7E 07 04 01 01 FF FF 00 EF` | Turn on |
| Power off | `7E 07 04 01 00 FF FF 00 EF` | Turn off |
| Set color | `7E 07 05 03 RR GG BB 10 EF` | Static RGB color |
| Set brightness | `7E 07 01 VV FF FF FF 00 EF` | Brightness 0-100 (app emits len `04`) |
| Set speed | `7E 04 02 VV FF FF FF 00 EF` | Animation speed 0-100 |
| Set animation | `7E 07 03 VV FF FF FF 00 EF` | Mode 0-212 (213 named modes) |
| Sync time | `7E 06 83 HH MM SS DW 00 EF` | Clock; weekday 1=Mon..7=Sun |
| Set timer | `7E 07 82 HH MM 00 TT DD EF` | TT 0=on-timer/1=off-timer; DD = days bitmask, bit7 enables, bits 0-6 = Mon..Sun |

The full ~70-opcode map (scenes, DIY image upload, rhythm, mesh groups, OTA)
is documented in `device-specs/devices/lotuslamp-x.yaml`.

### Variants worth knowing about

- **E2/E3 frame families** (`8E …` and `2E … 2F`): other device types sharing
  this app (pixel strips, curtain/TV backlights). See the spec for framing.
- **Connectionless control**: the phone can advertise commands itself —
  company ID `0xE190`/`0xE290` for broadcast, `0xBE99` for mesh groups
  (22-byte packet, CRC16 derived from the BLE CRC-24 core).
- **Encrypted firmware** (`ELK*` names, `*` as 4th character): wraps the
  power/mode/brightness frames in XOR obfuscation with an app-embedded preset
  key. Obfuscation, not security.

## Open Questions

- Exact `0xFFF4` notification payload semantics (state readback) — needs a
  live HCI capture.
- Which opcodes beyond power/mode/brightness take the obfuscated frame on
  `ELK*` firmware.
- Mesh group provisioning flow (familyId/roomId/groupId assignment).
- Only the MELK-OA10 is live-tested (by the lotus-lamp library); other models
  may shuffle mode numbers.

## Tools Used

- [x] APK static analysis (jadx)
- [x] Community open-source implementation ([lotus-lamp](https://github.com/wporter82/lotus-lamp-python), live-tested)
- [ ] HCI snoop (pending — notify-channel semantics, mesh provisioning)

## References

- [lotus-lamp on PyPI](https://pypi.org/project/lotus-lamp/) — independent reverse engineering, tested on MELK-OA10
- [wporter82/lotus-lamp-python](https://github.com/wporter82/lotus-lamp-python) — protocol documentation (docs/PROTOCOL.md) and the 213-mode table
- [LotusLamp X on Google Play](https://play.google.com/store/apps/details?id=com.szelk.ledlamppro)
- The `elk-bledom-led-strip` and `wl-smartled-pixel-strips` device specs — same 9-byte `7E…EF` frame family

## Contributors

- @wporter82 — lotus-lamp library, LotusLamp X BLE protocol reverse engineering
