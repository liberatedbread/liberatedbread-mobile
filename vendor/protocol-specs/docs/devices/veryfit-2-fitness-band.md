# Veryfit 2.0 Fitness Band (ID107 / ID111 class)

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: Unknown ODM (sold under Makibes and other brands; companion app Veryfit 2.0, `com.veryfit.multi`)
> **Manufacturer Status**: Abandoned

## Overview

The ID107/ID111-class fitness bands (~2016, Nordic nRF51822, Si1142 heart-rate
sensor, Kionix kx022 accelerometer) are driven by the **Veryfit 2.0** app. This
spec was promoted from a mis-attribution appendix in
[m6-fitness-band.yaml](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/m6-fitness-band.yaml):
the protocol was derived from a clean-room decompile of Veryfit 2.0 V2.0.37
(`com.veryfit.multi`, APK sha256
`98fab69b465f77f84b44d7ea859678a115474999691e72b2c814716a8aa6d530`) and does
**not** apply to the Telink-based M6 band. It was corroborated on the wire by a
third-party BlueZ session against a real ID107 HR.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | ID107 / ID107 HR / ID111 (family) |
| Chipset | Nordic nRF51822 |
| Radio | BLE 4.0 |
| Sensors | Si1142 optical HR, Kionix kx022 accelerometer |
| FCC ID | Not established |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `ID107 HR`-style local name |
| Passphrase protection | not_applicable |
| Confidence | medium (public source + app analysis; not replayed here) |

No pairing or bonding exists anywhere in the protocol: scan for service
`00000af0`, connect, enable notifications on `00000af7`, send the bind frame,
and the band is bound. The band accepts one connection at a time, so "rebinding"
to a new client is just the new client connecting and binding — an explicit
unbind command also exists.

**Factory reset**: an over-the-air "one-key restore" exists (settings command
0x03, key 0x27), but its payload bytes and exact effect are not established —
treat as unknown and undocumented rather than guessed.

## Protocol Summary

All frames are **20 bytes, zero-padded**: byte 0 = command ID, byte 1 = key,
bytes 2–19 = key-specific payload.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0x0AF0` | Veryfit 2.0 Command Service | Entire app protocol |
| `0x1530` | Nordic Legacy DFU | OTA via Nordic buttonless DFU (bootloader mode) |

Characteristics of `0x0AF0`: `0x0AF6` normal write, `0x0AF7` normal notify,
`0x0AF1` health write, `0x0AF2` health notify. Normal commands go to
`0x0AF6`/`0x0AF7`; health sync (command ID `0x08`) runs over
`0x0AF1`/`0x0AF2`.

Command IDs: firmware update `0x01`, get-info `0x02`, settings `0x03`,
bind/unbind `0x04`, notify `0x05`, app control `0x06`, BLE control `0x07`,
health data `0x08`, dump-stack `0x20`, log `0x21`, restart `0xF0`, factory
`0xAA`.

### Commands

#### Command: Bind (cmd `0x04`, key `0x01`)

**Request** (20 bytes, zero-padded):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Command ID `0x04` |
| 1 | 1 | Key `0x01` (bind) |
| 2 | 1 | Platform marker `0x02` (Android) |
| 3 | 1 | Client Android API level (`Build.VERSION.SDK_INT`) |
| 4 | 2 | Magic `55 AA` |
| 6 | 14 | Zero padding |

**Response** (on `0x0AF7`): same cmd/key, byte 2 = `0x00` on success.

#### Command: Get real-time data (cmd `0x02`, key `0xA0`)

Request is `02 A0` followed by 18 zero bytes. A real ID107 HR answered with
`02 a0 23 00 00 00 01 00 00 00 19 00 00 00 92 00 00 00 00 00` — little-endian
32-bit counters after the key, but the exact field assignment is **not**
established.

Further keys (frame shape identical; payload layouts not established):
get-info keys `0x01`/`0x02`/`0x03`/`0x04`/`0x05` (basic/function/time/MAC/
battery); app-control keys mic `0x01`, camera `0x02`, single-sport `0x03`,
find-band `0x04`; notify keys incoming-call `0x01`, call-status `0x02`,
message `0x03`, missed-message `0x04`. Health-sync keys (on the health
channel): request `0x01`, success `0x02`, data types `0x03`–`0x08`, finished
`0xEE`, error `0xFF`.

## Tools Used

- [x] apktool / smali static analysis of Veryfit 2.0 V2.0.37
- [x] Third-party BlueZ (bluetoothctl) on-wire GATT capture

## References

- [g7smy.co.uk — BLE on the Raspberry Pi (ID107 HR GATT capture)](https://www.g7smy.co.uk/2017/05/bluetooth-low-energy-ble-on-the-raspberry-pi/)
- [Veryfit 2.0 versions (uptodown)](https://veryfit-2-0.en.uptodown.com/android/versions)
- [4PDA ID107 thread](https://4pda.to/forum/index.php?showtopic=777752)
- [ID107 hardware notes](https://saturn.ffzg.hr/rot13/index.cgi?action=unplug)
- [M6 spec (mis-attribution history)](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/m6-fitness-band.yaml)

## Contributors

- Liberated Bread research (promoted from m6-fitness-band appendix, cross-checked 2026-08)
