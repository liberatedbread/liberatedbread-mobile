# iPixel Color LED Matrix Panel (TIRO/Heaton)

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: Shenzhen Heaton Technology Co., Ltd. / TIRO (OEM; many storefront brands)
> **Manufacturer Status**: Active

## Overview

The ubiquitous flexible silicone RGB LED matrix panel / scrolling sign sold on AliExpress, Amazon and regional marketplaces for car rear windows, shop fronts and advertising tickers — 5 V USB powered, often IP65, adhesive backing, in sizes from 32×16 up to 448×32 pixels. Known re-seller SKUs include **JTPD-03-011** (many sizes, "QYJSD" and other labels) and the **HCZ-001 / HCZ-002** "Smart Car Screen" panels. There is no single model number; all of them are driven by the **iPixel Color** app (`com.wifiled.ipixels`).

The panel is built on a **JieLi BLE SoC** and is controlled entirely over local BLE with **no pairing, bonding, or encryption**. Several working FOSS clients already exist — the device is usable cloud-free today. The vendor cloud (Heaton) is only a clip-art store and firmware-update service.

**Same OEM family as [led-helmet-display](led-helmet-display.md)** ("TIRO FA02" family): same FA02 command characteristic, framing convention, JieLi OTA machinery and Heaton cloud backend — but a different opcode map and panel geometries, so the command tables are not interchangeable.

**Family boundary — read this first.** These are *not* this device despite similar marketplace appearance: CoolLED1248 / Juntong ([coolledx-led-sign](coolledx-led-sign.md)), the LOY family (service `FFF0`), and the Quintic AES-128-ECB Shining Mask family. This family is identified by the **FA02** write characteristic under service `0x00FA` and `LED_BLE…` advertising names.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | No single model number — OEM platform; marketplace SKUs include JTPD-03-011, HCZ-001, HCZ-002 |
| Display | RGB LED matrix, 32×16 … 448×32 pixels (query the device — listings are unreliable; one HCZ-001 listing claims an impossible "32×23") |
| Chipset | JieLi BLE SoC (firmware in JieLi OTA format, chip-key scrambled) |
| Radio | BLE; some variants add Wi-Fi (undocumented path) and an IR remote |
| FCC ID | Unknown (marketplace listings carry no FCC ID) |
| Firmware obtained | 8 OTA images captured from the vendor cloud 2026-08-19 (sha256s in the spec's `sources`) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | BLE name prefix `LED_BLE` |
| Passphrase protection | not_applicable (a password mechanism exists in the protocol; flag 255 = no password is the norm) |
| Confidence | high (multiple FOSS clients do this on real hardware) |

Power the panel on, scan for the `LED_BLE` prefix, connect, locate FA02 (write) and the notify characteristic (FA03, or vendor UUID `d44bc439-…` on some firmware), enable notifications, then send the time-sync command — the panel replies with a device-info record whose byte 4 maps to the panel geometry.

**Factory reset**: no physical procedure is documented. The `clear` command (`04 00 03 80` to FA02) is documented by community clients as wiping all stored content and settings — a software factory reset (confidence: low; inferred, not observed).

**Rebinding**: there is no network to rebind. If a client cannot connect, the usual cause is the vendor app still holding the single BLE connection.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `000000fa-0000-1000-8000-00805f9b34fb` | iPixel Command Service | All display commands |
| `0000ae00-0000-1000-8000-00805f9b34fb` | JieLi OTA Service | Firmware update (presence inferred from the bundled JieLi OTA SDK — hypothesis) |

| UUID | Name | Properties | Purpose |
|------|------|------------|---------|
| `0000fa02-…` | Display Command | Write, Write Without Response | All commands (frame format below) |
| `0000fa03-…` | Display Notify | Notify | Command ACKs, device-info response. Some firmware uses vendor UUID `d44bc439-abfd-45a2-b575-925416129601` instead — enumerate, don't hardcode |
| `0000ae01-…` / `0000ae02-…` | JieLi OTA Write / Notify | Write / Notify | Firmware update data/result |

### Command frame format

All commands are raw byte arrays written to FA02:

| Offset | Length | Description |
|--------|--------|-------------|
| 0–1 | 2 | Total frame length, little-endian u16 (covers the whole frame) |
| 2–3 | 2 | Opcode, little-endian u16; the high byte sub-selects within a command group |
| 4.. | N−4 | Payload |

### Commands

| Opcode | Frame | Meaning |
|--------|-------|---------|
| `0x0107` | `05 00 07 01 v` | Power on/off |
| `0x8004` | `05 00 04 80 v` | Brightness 0–100 |
| `0x0104` | `05 00 04 01 v` | DIY ("fun") mode on/off |
| `0x0105` | `0A 00 05 01 00 r g b x y` | Set one pixel (DIY mode) |
| `0x8006` | `05 00 06 80 v` | Orientation, index 0–3 |
| `0x0106` | `0B 00 06 01 style fmt24 showdate yr mo day dow` | Clock mode (style 0–8) |
| `0x8001` | `08 00 01 80 h m s lang` | Sync time; panel replies with device info (byte 4 = device-type → geometry map, byte 10 = password flag) |
| `0x0201` | `10 00 01 02 style l1..l11` | Music-rhythm mode, 11 level bands (0–15) |
| `0x0200` | `06 00 00 02 t style` | Alternate rhythm mode |
| `0x8008` | `07 00 08 80 01 00 slot` | Show stored slot 1–9 (community docs also record a 5-byte `0x8007` variant — likely firmware-revision dependent) |
| `0x0102` | `07 00 02 01 01 00 slot` | Delete a stored slot |
| `0x8003` | `04 00 03 80` | Clear all stored content + settings |
| `0x0002` / `0x0003` | windowed | PNG / GIF upload — see below |

**Image/animation upload** (`0x0002` PNG, `0x0003` GIF): the image is resized client-side to the panel geometry and sent in ~12 KB windows. Every window is a complete frame: u16-LE length, opcode bytes, option byte (`0x00` first window, `0x02` continuation), u32-LE total payload size, u32-LE CRC32 of the payload, tail byte (`0x00` PNG / `0x02` GIF), save slot (0 = show only, 1–9 = store), then the chunk. Each window is ACKed on the notify characteristic before the next is sent. Text is rendered client-side to an image — there is no separate text wire format.

## Cloud Dependency

The device is **fully usable without the cloud** — BLE models have no internet path at all; only the companion app talks to the Heaton backend (all hosts alive 2026-08-19):

- `POST manage.heaton.com.cn/api/rm/getFirmwareInfo` — firmware checks (form body `appid=137&project_no=<TR…>&version=<n>`; answered unauthenticated with a browser-like User-Agent; images download from `images.heaton.com.cn` only with a matching Referer)
- `api.e-toys.cn` — clip-art/material library
- `app.heaton.cn` — app config JSON, manuals, logos

**If the Heaton cloud dies**: everything local keeps working — power, brightness, modes, clock, DIY drawing, PNG/GIF upload, slot management. What breaks is the clip-art library and OTA checks, and a captured firmware image can still be flashed via the local JieLi OTA service.

**Home Assistant guidance**: use [cagcoach/ha-ipixel-color](https://github.com/cagcoach/ha-ipixel-color) (HACS) or the [ESPHome component](https://github.com/DonKracho/ESPHome-component-iPixel-ble); for scripting, [pypixelcolor](https://github.com/lucagoc/pypixelcolor) is the cleanest reference.

## Tools Used

- [x] APK decompilation (jadx, 14,242 classes) — iPixel Color 3.7.6
- [x] Live vendor cloud API probe (firmware info + 8 image downloads)
- [x] Cross-verification against three independent FOSS implementations
- [ ] HCI snoop capture (pending — no hardware on hand)

## References

- [lucagoc/pypixelcolor](https://github.com/lucagoc/pypixelcolor) — Python client/CLI; byte formats cross-checked here
- [cagcoach/ha-ipixel-color](https://github.com/cagcoach/ha-ipixel-color) — HA integration + protocol documentation
- [DonKracho/ESPHome-component-iPixel-ble](https://github.com/DonKracho/ESPHome-component-iPixel-ble)
- [yewolf RE blog](https://yewolf.fr/blog/reverse-engineering-a-cheap-led-matrix/) — original write-up
- [iPixel Color on Google Play](https://play.google.com/store/apps/details?id=com.wifiled.ipixels) — v3.7.6 analysed (base APK sha256 `1fe5cd3a…37c76a`)

## Contributors

- APK static analysis (jadx), cloud API probes, community cross-verification — research dossiers 2026-08-19
