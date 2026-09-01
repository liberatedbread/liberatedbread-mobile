# Hello Fairy Fairy / Curtain / Tree Lights

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: Avatar Controls (Hello Fairy brand)
> **Manufacturer Status**: Active (protocol closed/proprietary)

## Overview

Hello Fairy is Avatar Controls' brand of app-controlled addressable light
strings — fairy/string lights, curtain lights, Christmas-tree lights (some with
a controllable tree-top star), wall "painting" lamps, plus solar and battery
variants. Everything is driven over Bluetooth LE from the **Hello Fairy** phone
app (`com.lenzetech.hellofairy`); there is no Wi-Fi, no cloud pairing, and no
account. That makes these devices excellent candidates for local-only control:
the BLE protocol documented here is the *entire* control surface, and the
vendor cloud is only used for firmware images, scene artwork and telemetry.

The protocol has been fully mapped statically from the vendor app (v3.3.3) —
services, framing, checksums and the core opcode set — but has **not yet been
verified against live hardware**. The machine-readable spec is
[`hello-fairy.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/hello-fairy.yaml).

## Hardware

| Property | Value |
|----------|-------|
| Model numbers | Reported by the device via GetDeviceInfo (e.g. `BMSL64`); dozens of SKUs |
| Chipset | Lenze ST17H66 BLE SoC (most common); ESP32 and Bluetrum variants exist |
| Radio | BLE |
| Firmware | Public Intel HEX / .bin / .fot images via the vendor OTA manifest |

## Initial Setup

No provisioning is needed — the device advertises as soon as it is powered.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised name | contains `Hello Fairy` |
| Passphrase protection | not_applicable |
| Confidence | medium (static app analysis; not yet run against hardware) |

**Factory reset**: there is no credential or network state to clear — nothing
binds the device to a phone or account. If the app can't connect, the usual
cause is that the device is already connected to another phone (only one BLE
central at a time): remove power for a few seconds and reconnect.

**Rebinding to a new controller**: just connect from the new one. If the old
phone keeps grabbing the link, remove the device from the vendor app (and from
the OS Bluetooth list if a bond was cached) first.

## Protocol Summary

All control happens on one ISSC-style transparent-UART GATT service:

| UUID | Name | Description |
|------|------|-------------|
| `49535343-fe7d-4ae5-8fa9-9fafd205e455` | Control service | Primary service |
| `49535343-8841-43f4-a8d4-ecbe34729bb3` | Command write | All commands written here |
| `49535343-1e4d-4bd9-ba61-23c647249616` | Response notify | Enable notifications **first** |

Command frame: `[0xAA][cmd][length][payload...][sum8]` where `sum8` is the sum
of all preceding bytes (head included) mod 256. Responses arrive on the notify
characteristic in the same framing. Multi-byte payload fields are big-endian.
A second framing — `[0xBB][cmd][length u32 BE][payload][0xBB]` — is used only
for bulk DIY/GIF file transfer.

### Commands (core set)

| Cmd | Name | Payload |
|-----|------|---------|
| `0x00` | Get device info | empty — returns fw version, model string, LED count, capabilities |
| `0x01` | Get device status | empty — countdown, power, active mode, mode state |
| `0x02` | Power | 1 byte: `0x01` on / `0x00` off |
| `0x03` | Set light mode | sub-mode byte `0x00` warm-white / `0x01` HSV / `0x02` scene / `0x03` music, then mode fields |
| `0x04` | Countdown | seconds u32 BE + enable byte |
| `0x05` | Set time | epoch u32 BE + tz sign + tz offset minutes u16 BE |
| `0x06`/`0x07` | Schedule timers | read/write 4-byte records (slots 1-4 / 5-8) |
| `0x09` | Battery level | empty — returns version + level (battery SKUs) |
| `0x0A` | Series / segments | empty |
| `0x0B` | Power mode | `[0x00]` — returns SAVING/POWER |
| `0x0C` | Scene speed | empty (get) / 1 byte 0-100 (set) |
| `0x14` | Current limit | empty (get) / u16 BE (set, advanced) |
| `0x30`-`0x33` | File / DIY transfer | GIF & DIY-mode upload (see spec) |

The HSV sub-mode of `0x03` takes hue (0-360), saturation and value (both
per-mille, 0-1000) as big-endian u16s — that is the colour control.

### Firmware updates (OTA)

Firmware images for every model are **public**, listed in plain JSON at
`https://hellofairyota.s3.amazonaws.com/hello_fairy_ota_pro.json` and keyed by
the model string the device reports. On the common ST17H66-based units the
update runs over a dedicated OTA service (`5833ff01-…`): writing `[01 02]`
reboots the device into an OTA identity that re-advertises at **MAC+1**, then
partitions (CRC16/MODBUS-checked) are streamed and a final `[04]` reboots into
the new firmware. ESP32 SKUs use a Nordic-DFU-style service; Bluetrum (.fot)
SKUs are not yet mapped. Flashing firmware is an advanced operation — only use
the image matching your model string.

!!! note "Privacy"
    The vendor app (not the device) sends telemetry — device MAC, model,
    firmware version, GATT UUID list — to a vendor backend at
    `121.40.220.76:20003`, and fetches cloud-storage credentials at runtime.
    A local-control client needs neither.

## Open Questions

- Nothing is wire-verified yet: the whole map comes from static analysis of
  the vendor app. First live capture should cover connect → info → status →
  power → colour.
- The device→app event opcodes (`0xA0`-`0xE0`) are only partially mapped.
- The vendor app's device-lock ("password") feature: wire mechanism unknown —
  if a unit stops responding after a password was set, this is the suspect.
- Bluetrum (.fot) OTA transport undocumented; ESP32 OTA flow only sketched.

## Tools Used

- [x] APK static analysis (jadx) of `com.lenzetech.hellofairy` v3.3.3
- [x] Public OTA manifest + firmware image formats (47 images surveyed)
- [ ] HCI snoop against live hardware (pending — highest priority)

## References

- [Hello Fairy on Google Play](https://play.google.com/store/apps/details?id=com.lenzetech.hellofairy)
- [Public OTA manifest](https://hellofairyota.s3.amazonaws.com/hello_fairy_ota_pro.json)
- [Historical APK versions](https://d225sgx93xedrp.cloudfront.net/hellofairy_download/apk/HelloFairy_historical.html)

## Contributors

- Liberated Bread research — static protocol recovery from the vendor app
