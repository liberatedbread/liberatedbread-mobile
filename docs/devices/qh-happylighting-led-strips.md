# Qianghe "HappyLighting" (Triones / QHM) BLE LED Strip Controller

> **Status**: Complete (app-analysis based; no hardware capture in this project)
> **Protocol**: BLE (GATT)
> **Manufacturer**: Shenzhen Qianghe Technology Co., Ltd. (qh-tek.com)
> **Manufacturer Status**: Active (protocol closed; reverse engineered from the app)

## Overview

Cheap BLE RGB(W) LED strip controllers driven by the vendor **HappyLighting**
app (Android `com.qh.Happylight`, iOS id1145694075, Huawei AppGallery
C104507761). The reference instance is the AliExpress 3256812708626256
4×72-LED USB car interior strip kit: four rigid 5050 RGB bars on an inline
"LED LAMP" controller whose QR code resolves to the HappyLighting download
portal — that QR decode is what ties the hardware to the app.

This is the **Triones / HappyLighting / QHM** family — not Tuya, and not the
ELK-BLEDOM (duoCo) family covered by the
`elk-bledom-led-strip` spec; the packet formats are
unrelated. The family is natively supported by Home Assistant's `led_ble`
integration.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | None marked; "LED LAMP" / "LED Controller" inline box |
| LEDs | 4× rigid 5050 RGB bars, 18 LEDs each (72 total), USB 5V |
| Chipset | Unknown |
| Radio | BLE |
| FCC ID | Unknown |

## Initial Setup

No provisioning — the controller advertises when powered and takes writes
from any central with no pairing or account. See
[Initial Device Setup](../protocols/device-setup.md); the machine-readable
spec mirrors this in `device.setup`.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised name | `Dream#` / `Dream~` / `Dream=` / `QLAMP` / `QHM*` / `Triones~` |
| Passphrase protection | not_applicable |
| Confidence | medium (from decompiled app; not replayed against hardware) |

**Factory reset**: no credential or pairing state exists to clear, and no
dedicated reset procedure was found in the app. Power-cycling returns the
controller to its default state. Confidence: low.

**Rebinding to a new controller**: trivial — there is no bonding or owner
binding; any central in range can connect and take control.

## Protocol Summary

### BLE Services

Two GATT layouts exist; the app picks by which service the unit exposes.
Which layout a given controller revision uses is unconfirmed — try
0xFFD5/0xFFD9 first.

| UUID | Name | Description |
|------|------|-------------|
| `0xFFD5` | Qianghe command service | Current app builds write commands here |
| `0xFFD9` | Write | Command frames (write / write-without-response) |
| `0xFFE0` | Qianghe legacy service | Older controller revisions |
| `0xFFE1` | Write | Same command frames as 0xFFD9 |
| `0xFFE2` | Notify | Status replies (legacy layout) |

### Commands

Frames are short fixed literals: no length prefix, no checksum, no sequence
byte. Each write is a complete command.

#### Command: Power on/off

**Request**:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0xCC` opcode |
| 1 | 1 | `0x23` = on, `0x24` = off |
| 2 | 1 | `0x33` trailer |

So power on = `CC 23 33`, off = `CC 24 33`.

#### Command: Static color

**Request** (`56 R G B W F0 AA`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x56` opcode (`0x57` … `0x75` variant on a second app code path) |
| 1 | 1 | Red (0–255) |
| 2 | 1 | Green (0–255) |
| 3 | 1 | Blue (0–255) |
| 4 | 1 | White channel; app scales it with brightness on RGBW hardware (0 on RGB-only) |
| 5 | 1 | `0xF0` |
| 6 | 1 | `0xAA` trailer |

#### Command: Effect mode

**Request** (`BB <mode> <speed> 44`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0xBB` opcode |
| 1 | 1 | Mode index (app's effect list; full table not extracted) |
| 2 | 1 | Speed (0–255) |
| 3 | 1 | `0x44` trailer |

#### Command: Status query

**Request**: `EF 01 77`

**Response**: notification (0xFFE2 on the legacy layout); the app parses
state fields from byte offsets 3–9 of the value. Per-field semantics are
unverified.

#### Command: Mic/music sensitivity

Fixed literal `69 00 00 F0 96` observed on the 0xFFD5/0xFFD9 layout; which
byte carries the sensitivity value was not established.

## Cloud Dependency

None. BLE-local only: the app works with no account and no internet, and the
decompiled tree contains no OTA or firmware-download URLs (only qh-tek.com
privacy/about pages). Ad/analytics SDKs are bundled but not functionally
required.

## Tools Used

- [x] APK decompilation (jadx) — com.qh.Happylight 1.6.50
- [x] QR decode of the controller's app-download code (OpenCV, from listing image)
- [ ] BLE capture / hardware replay (not performed)

## References

- [Home Assistant led_ble integration](https://www.home-assistant.io/integrations/led_ble/)
- [sysofwan/ha-triones (archived)](https://github.com/sysofwan/ha-triones)
- [8none1/pytrionesmqtt](https://github.com/8none1/pytrionesmqtt)
- [MikeCoder96/HappyLighting-py](https://github.com/MikeCoder96/HappyLighting-py)
- [HA community thread: Triones/HappyLighting BLE lights](https://community.home-assistant.io/t/356011)

## Contributors

- APK static analysis (jadx), 2026-08-19
