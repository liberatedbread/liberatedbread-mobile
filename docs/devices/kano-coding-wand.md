# Kano Harry Potter Coding Kit Wand

> **Status**: Spec Available (unverified)
> **Protocol**: BLE
> **Manufacturer**: Kano Computing Limited (London)
> **Manufacturer Status**: Shutdown — administrators appointed 2023-06-06; the kit is discontinued and the companion app's last release is from 2021

## Overview

The wand from Kano's 2018 Harry Potter Coding Kit is a Nordic nRF52832 with a
9-axis IMU, one button, a vibration motor and an RGB LED, on two AAA cells. It
speaks BLE GATT straight to the tablet or computer running the Kano app — no
hub, no cloud — streaming its orientation as a quaternion, notifying button
presses, and taking LED-colour and vibration writes. Turning that stream into
on-screen "spells" was the app's job, on the host; gesture recognition is out
of scope here. The spec makes the wand a gesture-input device and stops.

Kano published the wand's SDK itself: `@kano/devices-sdk` on npm (MIT,
October 2018) names every service and characteristic and encodes every write.
Its GitHub home has vanished, but the tarball survives, so this spec is the
vendor's own GATT layout rather than a reconstruction. Units and scaling of the
sensor values are not stated by the SDK and come from hobby clients.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised | Local name starting `Kano-Wand` (reported as `Kano-Wand-75-XX-XX`); no service UUID known to be advertised |
| Passphrase protection | not_applicable |
| Confidence | medium (the vendor SDK is a working open implementation; not replayed here) |

Fit two AAA cells (the blue LED lights; if not, check polarity), press the
button to wake the wand, connect, enable notifications on the button and
quaternion characteristics, write `01` to the quaternion-reset characteristic
once, and write `01` to the keep-alive characteristic periodically — the wand
drops the link after inactivity without any notification. The blue LED flashes
while the wand looks for a connection and goes steady once connected.

**Factory reset**: none documented. The wand stores no bond, credential or
owner; whether magnetometer calibration survives a battery change is unknown.
Pulling the batteries is the reset in practice.

**Rebinding**: BLE-only, nothing to rejoin. Any central may connect once the
previous one has gone.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| One central at a time | Yes (assumed — ordinary BLE peripheral) |
| Confidence | medium |

Nothing pairs: the vendor SDK and three independent clients connect with no
security parameters and read and write everything on a bare connection.
**Recovery**: close the Kano app or whatever client holds the wand, or pull a
battery for a moment.

## Protocol Summary

All custom UUIDs share the base `64a7xxxx-f691-4b93-a6f4-0968f5b648f8`.

| UUID | Name | Description |
|------|------|-------------|
| `64a70010-f691-4b93-a6f4-0968f5b648f8` | Information service | |
| `64a7000b-f691-4b93-a6f4-0968f5b648f8` | Organisation | Read; UTF-8 string |
| `64a70013-f691-4b93-a6f4-0968f5b648f8` | Software version | Read; UTF-8 string |
| `64a70001-f691-4b93-a6f4-0968f5b648f8` | Hardware build | Read; one byte |
| `64a70012-f691-4b93-a6f4-0968f5b648f8` | IO service | |
| `64a70007-f691-4b93-a6f4-0968f5b648f8` | Battery status | Read/notify; one byte, scale unknown |
| `64a7000d-f691-4b93-a6f4-0968f5b648f8` | User button | Read/notify; `01` pressed, `00` released |
| `64a70008-f691-4b93-a6f4-0968f5b648f8` | Vibration motor | Write one byte, pattern 1–7 |
| `64a70009-f691-4b93-a6f4-0968f5b648f8` | LED | Write `[on, rgb565 hi, rgb565 lo]` |
| `64a7000f-f691-4b93-a6f4-0968f5b648f8` | Keep-alive | Write `01` to stay awake |
| `64a70011-f691-4b93-a6f4-0968f5b648f8` | Sensor service | |
| `64a70002-f691-4b93-a6f4-0968f5b648f8` | Quaternions | Notify; 4 × int16 LE, w x y z, ÷1000 |
| `64a70004-f691-4b93-a6f4-0968f5b648f8` | Quaternion reset | Write `01` to zero the pose |
| `64a70021-f691-4b93-a6f4-0968f5b648f8` | Magnetometer calibration | Write `01`; notifies `02` done / `03` failed |
| `64a70014-f691-4b93-a6f4-0968f5b648f8` | Temperature | Read/notify; int16 LE, unit unknown |
| `64a7000a-…` / `64a7000c-…` | Raw / Motion | Named by the SDK, used by nothing; layout unknown |
| `0000fe59-0000-1000-8000-00805f9b34fb` | Nordic Secure DFU | Buttonless entry on `8ec90003-f315-4f60-9fb8-838830daea50` (advanced) |

**LED colour** is 16-bit RGB565, high byte first, after the on/off byte:
`rgb565 = ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3)`. Red is
`01 f8 00`, green `01 07 e0`, blue `01 00 1f`, white `01 ff ff`, off `00 00 00`.
`scripts/test_kano_coding_wand_spec.py` transcribes the packing and holds the
spec's vectors to it.

**Orientation** arrives as eight bytes — four signed 16-bit little-endian
integers in the order w, x, y, z, each the quaternion component × 1000 — in the
frame set by the last reset write. The hobby clients disagree with each other
on byte order and axis signs; the vendor SDK's reading is the one declared, and
confirming it on a wand is the top open item.

**Firmware update** is Nordic Secure DFU. The vendor SDK writes the stack's
set-name opcode (`02 <len> DFU-XX-XX`, the last two address bytes) and then
`01` to the buttonless characteristic, waits for the disconnect, and
reconnects to the bootloader by that name. Both writes are `advanced` in the
spec; whether the bootloader enforces signed images, and where images came
from, is not established.

See `device-specs/devices/kano-coding-wand.yaml` for the full machine-readable
spec.

## References

- [Kano Harry Potter Coding Kit build book (PDF, vendor CMS)](https://kanome-cms-media-production.kano.me/media/components/0d36bf7b-2968-4af6-8e04-dc5267ffd8f6.pdf)
- [@kano/devices-sdk on npm (Kano Computing, MIT)](https://www.npmjs.com/package/@kano/devices-sdk)
- [GammaGames/kano_wand](https://github.com/GammaGames/kano_wand)
- [Kano Wand Hack (Hackaday.io)](https://hackaday.io/project/161832-kano-wand-hack)
- [anzellai/wandkit](https://github.com/anzellai/wandkit)
- [Nordic Semiconductor press release, 2018-10-09](https://www.nordicsemi.com/Nordic-news/2018/10/Harry-Potter-Kano-Coding-Kit-employs-nRF52832-to-wirelessly-connect-magic-wand-with-app)
- [The Gazette notice 4374009 — appointment of administrators](https://www.thegazette.co.uk/notice/4374009)
- [Companies House 08375450 — insolvency](https://find-and-update.company-information.service.gov.uk/company/08375450/insolvency)
