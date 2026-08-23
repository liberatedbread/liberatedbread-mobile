# Govee H6001 Smart Bulb

> **Status**: Spec Available (untested by us)
> **Protocol**: BLE
> **Manufacturer**: Govee (Shenzhen Intellirocks Tech / iHoment)
> **Manufacturer Status**: Active

## Overview

BLE-only smart bulb from Govee's legacy bulb family (H6001, H6005; Minger
rebadges exist). Documented from static analysis of the Govee Home Android
app, cross-referenced with an on-device HCI-snoop capture of a real H6001
(chvolkmann/govee_btled) and two independent community protocol write-ups.
The protocol is the classic Govee 20-byte fixed packet with an XOR checksum
in the final byte, on the shared `00010203-…-1910` GATT profile.

Machine-readable spec: `device-specs/devices/govee-h6001-bulb.yaml`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | H6001 (sibling H6005; Minger-branded H6001s exist) |
| Radio | BLE only |
| Advertised name | `ihoment_H6001_…`, `Minger_H6001_…` or `Govee_H6001_…` (unconfirmed — no source records this bulb's name; the three forms are what the app's name grammar produces for a legacy sku) |
| Advertised service | `00010203-0405-0607-0809-0a0b0c0d1910` |
| Manufacturer company ID | `0xEC88` (60552) when the `88 EC` bytes lead the payload; firmware with a leading version byte reports `0x88XX` instead — match `88 EC` at payload offset 0 or 1. Bulb family goodsType = 20 |

The H6001 supports Govee's local Wi-Fi API alongside BLE per the Home
Assistant `govee_light_local` integration, though the BLE protocol here is
the documented local path.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `ihoment_H6001_…` |
| Passphrase protection | not_applicable |
| Confidence | high (on-device GATT profile confirmed; setup flow unverified) |

No pairing or bonding: the bulb advertises on power-up and accepts open BLE
writes from any connected central. Power on, scan, connect, write.

**Factory reset**: unverified. Rapid power cycling is the near-universal
reset for mains-powered smart bulbs and is what Govee's published help text
points users at, but the exact toggle count was not recovered — some
generations want five cycles, others three. Toggle power ~5 times (about a
second in each state) and watch for a self-initiated blink followed by
re-advertising as unprovisioned; if the bulb just comes back on unchanged,
try three cycles.

**Rebinding**: nothing to rejoin. The bulb is BLE-only and holds no bond —
any central may connect once the previous one disconnects.

## Protocol Summary

Every command is a **20-byte fixed-length packet**: byte 0 = `0x33` (control)
or `0xAA` (ACK/keep-alive), byte 19 = XOR of bytes 0–18. A short write is a
rejected write. While connected, a keep-alive `AA 01 00..00 AB` is sent
roughly every 2 s.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00010203-…-1910` | Govee Legacy Bulb Service | HCI-snoop-confirmed on-device profile |
| `00010203-…-2b11` | Control Write (write, write-without-response) | All control commands go here |
| `00010203-…-2b10` | Control Notify (read, notify) | ACKs and responses |
| `0000fd00-…-34fb` | Govee OTA Service | Firmware update; **unverified** — present in the app but no public H6001 GATT dump confirms it on-device |
| `0000fd01-…-34fb` | OTA Write (write) | — |
| `0000fd02-…-34fb` | OTA Notify (notify) | — |

The `0xFFE0`/`0xFFE1` profile sometimes attributed to this bulb belongs to
the H6101/H6104 sibling classes (see [Govee H6101/H6104 TV
Backlight](govee-h6101-backlight.md)), not to the H6001.

### Commands

#### Command: Power on / off

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x33` control prefix |
| 1 | 1 | `0x01` power command |
| 2 | 1 | `0x01` on / `0x00` off |
| 3–18 | 16 | Zero padding |
| 19 | 1 | XOR of bytes 0–18 |

Full frames: on = `33 01 01 00×16 33`; off = `33 01 00 00×16 32`.

#### Command: Set brightness

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x33` |
| 1 | 1 | `0x04` |
| 2 | 1 | Brightness, raw 0–255 (the vendor app maps its 1–100 % slider onto roughly `0x14`–`0xFE`) |
| 3–18 | 16 | Zero padding |
| 19 | 1 | XOR checksum |

#### Command: Set color

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x33` |
| 1 | 1 | `0x05` color/mode command |
| 2 | 1 | `0x02` manual color mode |
| 3–5 | 3 | R, G, B |
| 6–18 | 13 | Zero padding |
| 19 | 1 | XOR checksum |

White / color temperature uses fixed warm/cold shades rather than arbitrary
Kelvin: `33 05 02 FF FF FF 01 <shade R> <shade G> <shade B> 00×9 <xor>` —
the `0x01` flag selects the warm/cold-white LED set and the shade triple
comes from the vendor's fixed table. Additional color-mode sub-commands
exist in the wider family (music `0x01`, scene `0x04`, DIY `0x0A` per the
community H6127 notes).

#### Command: Keep-alive

`AA 01 00×17 AB`, sent every ~2 s while connected.

## Tools Used

- [ ] Static analysis of the Govee Home Android app (jadx)
- [ ] chvolkmann/govee_btled on-device HCI-snoop capture (third party)
- [ ] Community protocol notes (egold555, blog.coding.kiwi GATT dump)

## References

- [chvolkmann/govee_btled](https://github.com/chvolkmann/govee_btled)
- [egold555/Govee-Reverse-Engineering](https://github.com/egold555/Govee-Reverse-Engineering)
- [Reverse-engineering Govee smart lights](https://blog.coding.kiwi/reverse-engineering-govee-smart-lights/)
- [Rolandjg/Govee-bulb-control](https://github.com/Rolandjg/Govee-bulb-control) — tested on H6001 hardware
- [jonahclarsen/bluetooth_lights_controller](https://github.com/jonahclarsen/bluetooth_lights_controller)
- [axelson/govee_phx](https://github.com/axelson/govee_phx)
- [Home Assistant Govee lights local integration](https://www.home-assistant.io/integrations/govee_light_local/)

## Contributors

- @kimi - spec from app static analysis + third-party RE sources
