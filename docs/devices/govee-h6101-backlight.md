# Govee H6101/H6104 TV Backlight

> **Status**: Spec Available (app-derived, untested on hardware)
> **Protocol**: BLE
> **Manufacturer**: Govee (Shenzhen Intellirocks Tech / iHoment)
> **Manufacturer Status**: Active (these two models discontinued)

## Overview

Early BLE-only TV backlight strips, both discontinued (the app still
carries their modules). They are the odd family out: the **only** Govee
lights on the legacy `0xFFE0`/`0xFFE1` GATT profile — every other family,
from the H6001 bulb to current RGBIC strips, uses service
`00010203-…-1910`. The wire protocol itself is the shared Govee 20-byte
fixed packet. Documented from static analysis of the Govee Home Android app
(v7.5.30); no independent on-device capture of this pair is known, so
confidence is medium overall.

Machine-readable spec: `device-specs/devices/govee-h6101-backlight.yaml`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | H6101, H6104 |
| Radio | BLE only |
| Advertised name | `ihoment_H6101_…` / `ihoment_H6104_…` (unconfirmed; Minger rebadges of contemporary gear exist) |
| Advertised service | `0000ffe0-0000-1000-8000-00805f9b34fb` |
| Manufacturer company ID | `0xEC88` (60552), or `0x88XX` when a version byte leads the payload — match the `88 EC` bytes at offset 0 or 1. App-confirmed as the parser requirement, but unverified on the air for this discontinued pair |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `ihoment_H610…` |
| Passphrase protection | not_applicable |
| Confidence | medium (app-derived; no on-device capture) |

No pairing or bonding: the strips advertise on power-up and accept open
writes from any connected central. Power on, scan, connect, write to
`0xFFE1`.

**Factory reset**: unverified. Rapid power cycling is the near-universal
reset for mains-powered smart lights and what Govee's published help text
points users at, but the toggle count varies across the family. Toggle
power ~5 times (about a second in each state) and watch for a
self-initiated blink followed by re-advertising as unprovisioned; if the
strip just comes back on unchanged, try three cycles.

**Rebinding**: nothing to rejoin — BLE-only, no bond held; any central may
connect once the previous one disconnects.

## Protocol Summary

Same framing as the rest of the Govee family: 20-byte fixed packets, byte 0
= `0x33` (control) / `0xAA` (query), byte 19 = XOR of bytes 0–18. Write
ACKs echo the command id with payload byte 0 = 0 on success. A keep-alive
`AA 01 00..00 AB` goes out every ~2 s while connected.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000ffe0-…-34fb` | Govee Legacy Backlight Service | Used only by the H6101/H6104 pair (app-confirmed) |
| `0000ffe1-…-34fb` | Control Write/Notify (write, write-without-response, notify) | Single characteristic for commands, ACKs and group-control writes |

Group control in the app writes to `0xFFE1` under `0xFFE0` for these two
models specifically; other families get group writes on the standard
`…2b11` characteristic, with `FFE0`/`FFE1` as fallback only when the `1910`
service is absent.

### Commands

| Packet | Purpose |
|--------|---------|
| `33 01 01 00×16 33` | Power on |
| `33 01 00 00×16 32` | Power off |
| `33 04 <0–100> 00×16 <xor>` | Set brightness (percent) |
| `33 05 02 <R> <G> <B> 00×13 <xor>` | Set RGB color (manual mode) |
| `33 05 04 <id_lo> <id_hi> 00×14 <xor>` | Apply built-in scene (16-bit little-endian id) |
| `AA 01 00×17 AB` | Keep-alive / power-state query (response payload byte 0 = power) |
| `AA 04 …` / `AA 05 …` | Query brightness / current mode (payload byte 0 = sub-mode, rest = sub-mode state) |

Legacy color-mode sub-modes of `33 05`: `0x02` manual RGB, `0x04` scene,
`0x0A` DIY, `0x11` music.

## Tools Used

- [ ] Static analysis of the Govee Home Android app v7.5.30 (jadx)
- [ ] Community protocol notes for the shared framing (egold555, chvolkmann, blog.coding.kiwi)

## References

- [egold555/Govee-Reverse-Engineering](https://github.com/egold555/Govee-Reverse-Engineering)
- [chvolkmann/govee_btled](https://github.com/chvolkmann/govee_btled)
- [Reverse-engineering Govee smart lights](https://blog.coding.kiwi/reverse-engineering-govee-smart-lights/)

## Contributors

- @kimi - spec from app static analysis
