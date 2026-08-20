# Johnson JLX LDM330 / LDM130 Laser Distance Meter

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Johnson Level & Tool (Winho OEM platform)
> **Manufacturer Status**: Active

## Overview

The Johnson JLX LDM330 (model 40-6013) is a 330 ft Bluetooth laser distance
meter with an integrated angle sensor; the LDM130 is its 130 ft sibling. Both
pair with Johnson's "Measure-Up" app (Android package `com.winho.measure_up`).
The "winho" package name gives away the OEM platform: the same app codebase
also builds sibling-branded apps (Starrett STR3, Ronix, MeasureMate, IM2,
MeasureCam/TargetCam variants), so the protocol below likely covers a family
of rebadged meters.

The BLE protocol was recovered entirely by static analysis of the Measure-Up
APK — no hardware was in hand and no over-the-air capture exists. It is a
simple ASCII serial-style exchange over two GATT characteristics and looks
trivially implementable, but every byte here is untested against a real meter.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | LDM330 (40-6013); sibling LDM130 |
| Chipset | Unknown (BLE module not identified) |
| Radio | BLE (GATT server) |
| FCC ID | Not found |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Unknown — the app scans unfiltered and the user picks the meter from a list |
| Passphrase protection | not_applicable |
| Confidence | medium (decompiled app flow + vendor quick-start guide; never run) |

**Factory reset**: none exists or is needed. The meter holds no bonds,
credentials, or client state — the app connects without pairing. Removing the
batteries (2×AAA) is the only reset relevant to a BLE client.

**Rebinding to a new network**: not applicable (no Wi-Fi). Any client can
connect at any time; when the meter powers its radio down it sends a
`Zbleoff` notification first, and the vendor app simply reconnects.

To enable Bluetooth on the meter, press and hold its Bluetooth button (per
the vendor quick-start guide), then select the meter from the app's scan list.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000f150-0000-1000-8000-00805f9b34fb` | Winho LDM Service (hypothesis) | Service UUID is not pinned by the app; `0xF150` is a numbering-convention guess. Match characteristics, not the service. |
| `0000f151-0000-1000-8000-00805f9b34fb` | command_rx (write) | App → device commands (init, keep-alive, measure) |
| `0000f154-0000-1000-8000-00805f9b34fb` | data_tx (notify) | Device → app handshake and measurement frames |

### Commands

#### Command: init

**Request** (write to `f151`, 6 bytes, fixed):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 6 | `03 0D 0A 03 0D 0A` — sent after subscribing, and in reply to `Ztest01` |

#### Command: measure

**Request** (write to `f151`, 13 bytes):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x23` (`#`) header |
| 1 | 1 | `0x0A` (LF) header |
| 2 | 1 | ASCII command `'m'` |
| 3 | 9 | NUL padding |
| 12 | 1 | Checksum `0x9A` = 8-bit sum of bytes 0–11 |

Full bytes: `23 0A 6D 00 00 00 00 00 00 00 00 00 9A`

#### Command: link keep-alive

Answer to the device's `Ztest02` notification (write to `f151`, 13 bytes):
`23 0A 4C 69 6E 6B 00 00 00 00 00 00 BB` — `'#' LF "Link"`, NUL-padded,
checksum `0xBB`.

### Notifications (device → app, `f154`, 10-byte ASCII, NUL-padded)

| Frame | Meaning |
|-------|---------|
| `Ztest01` | Handshake request → client writes the init frame |
| `Ztest02` | Keep-alive request → client writes the link frame |
| `Zbleoff` | Meter is powering its BLE radio down; treat as clean disconnect |
| `error1`…`error6` | (Hypothesis) measurement failure codes; the app compares against these strings |
| other | Measurement frame, see below |

**Measurement frame**:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Type/prefix character; the vendor app discards it (meaning unknown) |
| 1 | 6 | Fixed-width ASCII decimal value, always **meters** (e.g. `12.345`) |
| 7 | 1 | Unit code = device display setting: `a`=m, `b`=ft, `c`=in, `d`=ft'in" 1/32, `e`=in 1/32, `f`=in 1/16, `g`=in 1/8, `h`=in 1/4, `i`=in 1/2, `j`=Taiwanese/Chinese foot |
| 8 | 2 | NUL padding |

The value is meters regardless of the unit code; the app converts for display.
The LDM330's angle sensor does not appear in the recovered BLE code — every
frame carries a single scalar distance, so angle is likely on-device only
(unverified).

## Family survey (Bluetooth laser distance meters)

| Family | Transport | Notes |
|--------|-----------|-------|
| **Winho platform (this spec)** | BLE | Johnson LDM130/LDM330 (Measure-Up app), Starrett STR3, Ronix, MeasureMate, IM2, MeasureCam/TargetCam builds share one codebase (AppName enum in the APK). ASCII frames over `f151`/`f154`. |
| Mileseey (P7/T7/R2B/M120/DT20-old, Suaoki rebadges) | BLE | Open protocol, transmits unit; supported by ImageMeter. Newer models (DT20-new, D5/D5T/D9 Pro, S50) moved to an encrypted protocol and are listed as unsupported by ImageMeter; D9 Pro rides the Tuya Smart Life app. |
| Bosch GLM 50 C / 100 C / PLR 30-50 C | Bluetooth Classic SPP | Reverse engineered; see philipptrenz/BOSCH-GLM-rangefinder (pymtprotocol). Remote trigger supported. |
| Bosch GLM xx-27 C generation | BLE | Newer closed BLE protocol (MeasureOn app); ImageMeter supports with manual protocol selection; partial RE in pklaus/bsch. |
| Leica DISTO (D1/D2/X3/X4/D810…) | BLE | Leica publishes its DISTO BLE interface documentation; ImageMeter supports broadly (some models need "Unencrypted App Mode"). |
| CEM iLDM series | BLE (new) / Classic (old) | Open protocol, transmits unit + remote trigger; ImageMeter-supported. |

See the [ImageMeter supported-devices table](https://www.imagemeter.com/manual/bluetooth/devices/)
for the broadest cross-brand catalog (70+ models, noting which transmit units
and which are encrypted/unsupported).

## Tools Used

- [x] apkeep (APK fetch from APKPure mirror) — `com.winho.measure_up` v1.0.1, sha256 `fc7ac7272f8604bc3636874055a4d6fe7f6b5e989ee02db1255ce9a9e9fd9deb`
- [x] jadx / apktool static analysis (output under `workspace/static/jlx-laser-distance-meter/`, gitignored)
- [ ] Wireshark / nRF Connect — no hardware available; **live verification still needed**

## References

- [Johnson LDM330 product page](https://www.johnsonlevel.com/P/1762/LaserDistanceMeterwAngleSensorandBluetooth)
- [LDM330 Quick Start Guide (PDF)](https://www.johnsonlevel.com/Content/files/Manuals/LDM%20330%20Quick%20Start%20Guide.pdf)
- [Measure-Up APK listing (APKPure mirror)](https://apkpure.net/measure-up/com.winho.measure_up)
- [philipptrenz/BOSCH-GLM-rangefinder](https://github.com/philipptrenz/BOSCH-GLM-rangefinder)
- [pklaus/bsch (Bosch BLE RE)](https://github.com/pklaus/bsch)
- [EEVblog: Mileseey D9 Pro Bluetooth thread](https://www.eevblog.com/forum/projects/mileseey-d9-pro-laser-distance-measure-ideas-for-interfacing-via-bluetooth/)

## Contributors

- Kimi Code CLI agent - initial static-analysis recovery (desk research only)
