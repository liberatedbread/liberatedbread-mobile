# SmartDawn Smart Lights

> **Status**: In Progress
> **Protocol**: BLE (Wi-Fi/UDP variants on the platform)
> **Manufacturer**: Hangzhou Daniao Technology Co., Ltd (SmartDawn / Minetom store brand)
> **Manufacturer Status**: Active

## Overview

SmartDawn (smartdawn.com) sells addressable-RGB holiday lighting — RGBIC
permanent outdoor string lights, icicle/net/curtain lights, meteor-shower
tubes, cone trees — controlled by the "SmartDawn" app. The products are
white-label builds of Hangzhou Daniao Technology's pixel-light platform (the
same stack as Daniao's SuperPix and legacy SmartPixel apps). This page
documents the local BLE command protocol, reconstructed from a decompile of
the official Android app (v1.2.4) and its bundled H5 JavaScript — no cloud
or account is needed for local control.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | JY25CUT-series curtain lights; HL1123 firecracker light; unnumbered string/icicle/net/meteor SKUs |
| Chipset | Unknown (FCC ID unresolved — internals not yet identified) |
| Radio | BLE (Wi-Fi on some Daniao-platform SKUs; which SmartDawn models include it is unverified) |
| FCC ID | Unresolved; manuals hosted on fccid.io (see References) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (BLE models) |
| Method | `ble_direct` |
| Setup AP / advertised name | `DN`-prefixed BLE name, 6-8 chars; Wi-Fi SKUs would expose AP `DN??????` (password `00000000`) |
| Passphrase protection | not_applicable (BLE) |
| Confidence | medium (from app code, not a live capture) |

Power the lights and they advertise immediately. Connect, subscribe to the
DDP and BIN notify characteristics, raise MTU, and send `M_TIME_SYNC` — then
commands flow. No pairing or authentication on the command path.

**Factory reset**: the protocol has `M_FACTORY_RESET` (mt=2598) and
`M_REBOOT` (mt=2599) commands (low confidence — from app code). The
controller also has a physical mode button: press to switch effects,
hold-and-release to turn off (per the FCC manual). No bonding state exists
to clear.

**Rebinding to a new network**: BLE control is network-independent. Wi-Fi
provisioning (Wi-Fi SKUs only) is re-done in place via the app's AP-mode
flow; nothing depends on the old network.

## Protocol Summary

Discovery: advertised local name is 6–8 chars starting with `DN`
(case-insensitive), plus the custom service UUID below; a 14-byte
manufacturer-data record carries firmware version, factory id, product type,
pixel width/height, group, vendor and run-mode flags.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00000074-1972-1925-3022-077119514e44` | Daniao DDP Service | Sole service; holds all channels below |
| `01020074-...-077119514e44` | DDP Write | Command writes (fragmented DDP/DNX packets) |
| `01010074-...-077119514e44` | DDP Notify | Command responses, state pushes |
| `02020074-...-077119514e44` | BIN Write | Bulk uploads (effects, animations, layouts) |
| `02010074-...-077119514e44` | BIN Notify | Bulk-channel responses/progress |
| `27923001-2072-...-077119514e44` | Uploader | Firmware upload (OTA flow) |

(All characteristic UUIDs except the Uploader share the
`1972-1925-3022-077119514e44` base; the Uploader's second group is `2072`
— confirmed in `BleUtils5` and SuperPix's `BleUtils3`.)

### Transport framing

Every logical packet is split into BLE writes of at most the negotiated
payload MTU (app requests ATT MTU 512; payload = MTU − 3, fallback 20), each
prefixed with a 4-byte fragment header:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Message serial (u8, per logical packet) |
| 1 | 1 | Total fragment count |
| 2 | 1 | Fragments remaining after this one (down to 0) |
| 3 | 1 | Channel tag: `0x00` on DDP; on BIN a buffer type — 1=TUTU_DOODLE, 2=TUTU_ERASE, 4=TUTU_RESTORE, 16=MUSIC_BIN |
| 4 | MTU−4 | Payload chunk |

Writes use `WRITE_TYPE_NO_RESPONSE` (BleUtils5 sets write type 2).

### Commands

Commands are protobuf messages under a 20-byte extended (DNX) header:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | 0xF0 (flag nibble 0xF, version 0) |
| 1 | 1 | from-role; app hardcodes 0x04 (gateway) |
| 2 | 2 | sn (u16 BE) |
| 4 | 2 | total length (u16 BE) |
| 6 | 2 | mt — message type (u16 BE) |
| 8 | 4 | cid (u32 BE, 0 from app) |
| 12 | 2 | osn (u16 BE) |
| 14 | 1 | rcode (0) |
| 15 | 1 | ts (random u8) |
| 16 | 2 | csum (u16 BE, app sends 0) |
| 18 | 2 | zeros |
| 20 | n | optional protobuf payload (default type `SimpleMessage {i1,i2,s1,s2,i3,i4}`) |

Core message types (full table in the YAML spec):

| mt | Command | Payload |
|----|---------|---------|
| 2504 | M_TIME_SYNC | TimeSync {offset, time, dst} |
| 2507 / 2508 | playlist loop / single play | none |
| 2509 | M_SET_BRIGHTNESS | SimpleMessage {i1} |
| 2514 / 2515 | power on / off | none |
| 2523 | M_SET_PLAYSPEED | SimpleMessage {i1} |
| 2598 / 2599 | factory reset / reboot | none |
| 2601 / 2603 / 2628 | palette / color mode / color ext | protobuf |
| 2604 / 2605 / 2606 | play next / prev / specific effect | effect ref for 2606 |
| 2611 / 2612 | music mode start / stop | – |
| 2650 / 2651 | device-mic music mode start / stop | none |
| 2701 / 2702 | doodle (live pixel session) start / end | SimpleMessage {i1,i2} |
| 237 | M_DEV_SHOW_PIXEL (single-pixel preview) | SimpleMessage {i1,i2} |
| 2104 | get running status | none |
| 2901–2933 | install/remove effects, apps, animations, layouts; firmware update | – |

Inbound highlights: `M_DEVICE_INFO_NOTIFY` (mt=2103, hardware/ports/fwVer/
effects/width/height), `M_POWER_STATUS_NOTIFY` (2105), `M_PLAY_INFO_NOTIFY`
(2610).

### Image / animation frames (pixel push)

**Confirmed live path (v1.2.4):** the app's draw / photo-to-light modes push
pixels over the **BIN channel**, not the DDP channel. `M_DOODLE_START`
(mt=2701, SimpleMessage {i1:1, i2:1}) opens the session; the canvas is then
sent as buffer arrays whose fragment-header tag byte is `TUTU_DOODLE` (1)
for incremental strokes or `TUTU_RESTORE` (4) for a full-canvas redraw
(`TUTU_ERASE` = 2 clears). The buffer payload is a palette-indexed raster
chunked at ~200 bytes: a 3-byte header `[x][y][colorCount ≤ 16]`, the RGB
palette (3 bytes/color), then per-pixel palette indices. `M_DOODLE_END`
(mt=2702) closes the session; `M_DOODLE_SCROLL` (mt=2715) scrolls it.
`M_DEV_SHOW_PIXEL` (mt=237) previews single pixels while drawing. Music
mode either starts the controller's own mic (`M_START_DEVICE_MIC`,
mt=2650) or, for phone-mic mode, computes FFT on the phone and drives
effect selection.

**Dormant encoder:** every Daniao H5 bundle checked (SmartDawn 1.2.4,
SuperPix 4.4.1, legacy SmartPixels) also ships `mkOrginDdp`, an encoder
for standard DDP DISPLAY packets (datatype 0x01, flag 0xE1, offset-ordered
fragments into a raster buffer) — but it has **no call sites** in any of
them. Treat DISPLAY-packet streaming as a legacy/dormant capability until
an on-air capture shows it in use; likewise the "PUSH flag latches the
frame" convention is inference from the header semantics, not confirmed.

**Stored animations:** multi-frame sequences install over the BIN channel
via `M_START_INSTALL_ANIMATION` / `M_INSTALL_ANIMATION_PACKET` /
`M_END_INSTALL_ANIMATION` (mt 2918–2920), from `p2p.proto`.

Machine-readable capability: the YAML spec declares
`features: [image_upload]` (rgb888, device-reported resolution, animation
via the BIN install flow) and `protocol_handler: "daniao_ddp"` for clients
that implement the fragment framing + packet encoders. Per-model
resolution (width × height) comes from the manufacturer-data record and
`M_DEVICE_INFO_NOTIFY` (mt=2103).

### Wi-Fi path (platform feature)

Same DDP framing over UDP port 4048; devices announce presence to app UDP
port 14040; AP-mode provisioning per the SmartPixel manual (`DN??????` /
`i5g*` hotspot, password `00000000`, WPA/OPEN only). Unverified which
SmartDawn SKUs ship Wi-Fi.

## Tools Used

- [x] jadx / apktool decompile of official SmartDawn.apk v1.2.4 (re-verified
  2026-08-08 against the vendor-CDN download, sha256 `58aaf3d6…ca07aa`;
  cross-checked with SuperPix `com.daniaokeji.cs` 4.4.1 and legacy
  SmartPixels decompiles)
- [x] H5 bundle analysis (assets/HTML — independent JS reimplementation)
- [x] Bundled protobuf schema `assets/HTML/p2p.proto` — authoritative
  message-type numbers and payload shapes
- [ ] Live BLE capture (not yet — see `research-notes/smartdawn-curtain-capture-plan.md`)

## References

- [SmartDawn smart lights collection](https://smartdawn.com/collections/smart-lights)
- [SmartDawn app on Google Play](https://play.google.com/store/apps/details?id=com.daniaokeji.smartdawn)
- [Hangzhou Daniao Technology](https://daniaokeji.com/) — ODM; hosts app APKs and manuals
- [FCC-hosted curtain-lights manual (JY25CUT models)](https://fccid.io/m/03e7be1bfdf844811e2d2cef87f6127da9424fa5c4ea7d89950479b3f244e0c4.pdf)
- Research store: `~/research/smartdawn-smart-lights/RESEARCH.md` (artifacts + hashes)

Open gaps: no on-air capture yet; BLE SoC unidentified; per-command payload
field semantics beyond SimpleMessage {i1} need capture or .proto extraction;
OTA firmware image not yet retrieved.

## Contributors

- OpenGreenIoT agent run 2026-08-03 — initial research and protocol map
