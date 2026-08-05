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
| `27923001-...-077119514e44` | Uploader | Firmware upload (OTA flow) |

(All characteristic UUIDs share the `1972-1925-3022-077119514e44` base.)

### Transport framing

Every logical packet is split into BLE writes of at most the negotiated
payload MTU (app requests ATT MTU 512; payload = MTU − 3, fallback 20), each
prefixed with a 4-byte fragment header:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Message serial (u8, per logical packet) |
| 1 | 1 | Total fragment count |
| 2 | 1 | Fragments remaining after this one (down to 0) |
| 3 | 1 | 0x00 |
| 4 | MTU−4 | Payload chunk |

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
| 2523 | M_SET_PLAY_SPEED | SimpleMessage {i1} |
| 2598 / 2599 | factory reset / reboot | none |
| 2601 / 2603 / 2628 | palette / color mode / color ext | protobuf |
| 2604 / 2605 / 2606 | play next / prev / specific effect | effect ref for 2606 |
| 2611 / 2612 | music mode start / stop | – |
| 2104 | get running status | none |
| 2901–2933 | install/remove effects, apps, animations, layouts; firmware update | – |

Inbound highlights: `M_DEVICE_INFO_NOTIFY` (mt=2103, hardware/ports/fwVer/
effects/width/height), `M_POWER_STATUS_NOTIFY` (2105), `M_PLAY_INFO_NOTIFY`
(2610).

### Image / animation frames (pixel push)

The platform's display surface is a raster buffer: the app's draw,
photo-to-light and music modes stream **standard DDP packets** with datatype
`DISPLAY` (0x01) to the DDP Write characteristic. Each packet carries pixel
bytes at a byte `offset` into the display buffer with `psize` length (header
layout in the table above); a frame larger than one packet is sent as
multiple packets at increasing offsets. Following the DDP convention the
platform derives from, the PUSH flag (0x01) on the final packet latches the
assembled buffer onto the LEDs — an inference from the header semantics, not
yet confirmed by capture. Animations are streamed: repeat the frame push at
the desired rate. Per-model resolution (width × height) comes from the
manufacturer-data record and `M_DEVICE_INFO_NOTIFY` (mt=2103).

Machine-readable capability: the YAML spec declares
`features: [image_upload]` (rgb888, device-reported resolution, animation via
streaming) and `protocol_handler: "daniao_ddp"` for clients that implement
the fragment framing + DDP packet encoder. Stored multi-frame effects also
exist via the BIN-channel install flow (mt 29xx) but are not yet mapped well
enough to encode.

### Wi-Fi path (platform feature)

Same DDP framing over UDP port 4048; devices announce presence to app UDP
port 14040; AP-mode provisioning per the SmartPixel manual (`DN??????` /
`i5g*` hotspot, password `00000000`, WPA/OPEN only). Unverified which
SmartDawn SKUs ship Wi-Fi.

## Tools Used

- [x] jadx / apktool decompile of official SmartDawn.apk v1.2.4
- [x] H5 bundle analysis (assets/HTML — independent JS reimplementation)
- [ ] Live BLE capture (not yet — see gaps below)

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
