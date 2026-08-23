# Smart LED Helmet Display (TIRO/Heaton)

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: TIRO Innovation Technology (Shenzhen) Co., Ltd. (OEM; many storefront brands)
> **Manufacturer Status**: Active

## Overview

A generic OEM Bluetooth-controlled RGB LED matrix panel (12×48 pixels) that straps onto a bicycle or motorcycle helmet, sold on Amazon/AliExpress/Shopify under dozens of brand names (Dpofirs, OPPWONG, Gelrova, YouRfocus, PChero, Masdio, …). Features: handlebar remote, turn-signal display driven by an accelerometer in the panel, speedometer ("ride info"), DIY image/animation/text upload, music-rhythm mode, daily on/off timers.

The companion app is **Shining Display** (`com.shiningdisplay.shiningdisplay`). The panel is built on a **JieLi BLE SoC** and is controlled entirely over local BLE with **no pairing, bonding, or encryption** — which makes it a good third-party-client target. The vendor cloud (Heaton) is only an optional content store.

**Family boundary — read this first.** Two other "LED helmet / LED mask display" ecosystems are *not* this device:

- The **LOY family** (LOY PLAY / LOY EYES apps, Shenzhen Yanse, BLE service `FFF0`, popled.cn cloud) — a different OEM and protocol. This spec does not cover it.
- The **Shining Mask / Shining Glasses / Magic Display family** ([magic-display](magic-display.md), shining-mask, shining-glasses) — Quintic QPP platform, AES-128-ECB encrypted ASCII commands. Different protocol despite overlapping seller names.

This document covers only the TIRO/Heaton, JieLi-based panel driven by the Shining Display app, identified by the **FA02** command characteristic.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | No single model number — OEM panel; project identifiers `TR2023-1248` (name prefix), `TR2302_1248_ble` (OTA project) |
| Display | RGB LED matrix, 12×48 pixels (per firmware project name) |
| Chipset | JieLi BLE SoC (firmware in JieLi `.ufw` format, chip-key scrambled) |
| Radio | BLE only — no Wi-Fi |
| FCC ID | Unknown (listings carry CE/RoHS claims only; a Chinese SRRC CMIIT ID may be on the hardware label) |
| Firmware obtained | `TR2306R009-2.ufw`, version_no 101 (2024-03-21), sha256 `2e8b34f8…cdbb9a2`, fetched live from the vendor API |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | BLE name prefix `TR2023-1248` (app-code constant — needs on-air confirmation) |
| Passphrase protection | not_applicable |
| Confidence | medium (app-derived, not replayed on hardware) |

Power the panel on, scan for the name prefix, connect, enumerate services and locate the write characteristic `0000fa02-…` by UUID. The app also enables notifications on `0000ae02-…` at connect time (command ACKs and OTA events arrive there) and negotiates MTU, chunking large writes to fit.

**Factory reset**: no physical procedure is documented. The app exposes a reset command — write `04 00 03 80` to FA02. What exactly it clears is inferred from the UI label only (confidence: low).

**Rebinding**: there is no network to rebind. If a client cannot connect, the usual cause is another central (the vendor app) still holding the single BLE connection.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| *(unpinned — see note)* | Helmet Display Command Service | Contains the FA02 command characteristic. The app never pins the containing service UUID; it enumerates all services and matches the characteristic. Clients must do the same. |
| `0000ae00-0000-1000-8000-00805f9b34fb` | JieLi OTA Service | Firmware update (JieLi `jl_bt_ota` SDK constants) |

| UUID | Name | Properties | Purpose |
|------|------|------------|---------|
| `0000fa02-0000-1000-8000-00805f9b34fb` | Display Command | Write | All display commands (frame format below) |
| `0000ae01-0000-1000-8000-00805f9b34fb` | JieLi OTA Write | Write | OTA data channel |
| `0000ae02-0000-1000-8000-00805f9b34fb` | JieLi OTA Notify | Notify | OTA results; also the general device→app feedback path (command ACKs, disconnect events; payload format unknown) |

### Command frame format

All commands are raw byte arrays written to FA02:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Total frame length N |
| 1 | 1 | `0x00` |
| 2 | 1 | Command opcode |
| 3 | 1 | Flag byte (`0x01` / `0x80` observed; `0x55` on OTA-start) — appears to sub-select within shared opcodes (**hypothesis**) |
| 4.. | N−4 | Payload |

### Commands

| Opcode | Frame | Meaning |
|--------|-------|---------|
| `0x01` | `0B 00 01 80` + 7 bytes | Sync time/date (payload packing not traced) |
| `0x03` / flag `0x80` | `04 00 03 80` | Reset device (no payload) |
| `0x03` / flag `0x01` | `05 00 03 01 v` | Set text scroll speed |
| `0x04` | `05 00 04 80 v` | Set brightness |
| `0x06` | `05 00 06 80 v` | Turn-signal direction; UI index 0–5 (index→meaning map unverified) |
| `0x07` | `05 00 07 01 v` | Display power on/off |
| `0x08` | `07 00 08 80 a b c` | Ride info / speedometer data (byte meanings untraced) |
| `0x0B` / flag `0x01` | `05 00 0B 01 v` | Gesture-sensing switch |
| `0x0B` / flag `0x80` | `06 00 0B 80 m0 m1` | Microphone / music-rhythm command |
| `0x0C` | `05 00 0C 01 v` | Voice-activation switch |
| `0xAA` / flag `0x55` | `05 00 AA 55 v` | OTA start; JieLi OTA data then flows over AE01/AE02 |

Bulk visual data (DIY canvas, image/text upload, playlists, scheduled on/off timers, screen mirroring) uses the same length-prefixed framing chunked by negotiated MTU, but the byte-level bitmap packing (12×48 RGB layout) was **not fully traced** — the dispatch functions are identified, the packing is not. See the spec's `remaining_unknowns`.

## Cloud Dependency

The device is **fully usable without the cloud** — it is BLE-only and never contacts the internet itself. Only the companion app talks to the Heaton backend (`manage.heaton.com.cn`, `images.heaton.com.cn`; both alive 2026-08-18), and only for:

- `POST /api/rm/getFirmwareInfo` — firmware update checks (form body `appid=141&project_no=TR2302_1248_ble&version=<int>`; exercised live, firmware v101 downloaded)
- `GET /api/rm/getMaterialUnderCategory` — preset pattern/animation library
- `GET /index.php/api/rn/product`, `GET /index.php/api/rn/resource` — product/resource metadata

**If the Heaton cloud dies**: local DIY images/animations/text, programs, brightness, power, turn signals, timers, screen mirroring and the handlebar remote all keep working. What breaks is the preset material library and OTA checks — and a captured `.ufw` can still be flashed over the local JieLi OTA service. No DNS redirect or keep-alive is needed for core function.

**Home Assistant guidance**: no existing HA/ESPHome integration was found for this family. The protocol is plain unauthenticated GATT, so a minimal client is 5-byte writes to FA02 (e.g. via `bleak`, or an ESPHome BLE client/`ble_client` write). Power, brightness, direction, and the gesture/voice switches are the immediately usable commands; subscribe to AE02 for ACKs.

## Tools Used

- [x] APK decompilation (jadx, 11,901 classes)
- [x] Hermes v96 bytecode disassembly (Pilfer/hermes_rs built from source — hbctool does not support HBC 96)
- [x] Live vendor cloud API probe (firmware info + image download)
- [ ] HCI snoop capture (pending — no hardware on hand)

## References

- [Shining Display on Google Play](https://play.google.com/store/apps/details?id=com.shiningdisplay.shiningdisplay) — v1.6.4 analysed (base APK sha256 `202be550…4733d3`)
- [TIRO Innovation Technology](https://www.tiro.cc/) — OEM (site live 2026-08-18)
- [GoneUp/mask-go](https://github.com/GoneUp/mask-go), [beclamide/mask-controller](https://github.com/beclamide/mask-controller), [shawnrancatore/shining-mask](https://github.com/shawnrancatore/shining-mask) — sibling Shining Mask family clients (AES-128-ECB Quintic platform); approach references only, **not** this protocol

## Contributors

- APK static analysis (jadx + Hermes disassembly), cloud API probes — research dossier 2026-08-18
