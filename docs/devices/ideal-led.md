# iDeal LED Pixel Strings & Trees

> **Status**: In Progress
> **Protocol**: BLE
> **Manufacturer**: Heaton OEM (app `com.tech.idealled`)
> **Manufacturer Status**: Active

## Overview

iDeal LED is the companion app for a family of Heaton-OEM addressable RGB products — pixel
strings, curtain/waterfall lights and pixel trees (firmware product codes TR21xx/TR22xx/TR23xx).
Everything the app does to the lights is local BLE; the vendor cloud only feeds the app's
firmware check and pattern library, so the hardware is fully usable without it.

The protocol belongs to the same OEM family as [Magic Display](magic-display.md) and
[Shining Glasses](shining-glasses.md): 16-byte `[length][ASCII opcode]` command blocks,
AES-128-ECB encrypted with a static, publicly documented key, written to the
`d44bc439-…-1296xx` characteristics. This branch of the family runs on a JieLi control chip
and speaks string/tree opcodes (SGLS/MULT/DOOD) rather than panel opcodes.
[iDotMatrix](idotmatrix.md) is a sibling by vendor ecosystem only — its wire protocol differs.

Two open-source projects independently implement this protocol:
[`8none1/idealLED`](https://github.com/8none1/idealLED) (which published the AES key and
ships HCI captures) and [`koying/ha_ideal_led_ble`](https://github.com/koying/ha_ideal_led_ble).

!!! warning "Brick hazard"
    The `8none1/idealLED` author [bricked one set of
    lights](https://www.whizzy.org/2023-12-14-bricked-xmas/) by sending out-of-family bytes
    during development. Stick to the documented opcode set; do not fuzz these devices.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | TR2107R (pixel tree), TR2110R (curtain), TR2202R (25-lamp string), others |
| Chipset | JieLi (JL; OTA via jl_bt_ota SDK, `.ufw` firmware container) |
| Radio | BLE |
| Pairing | None — no bonding, no auth |
| App | iDeal LED (`com.tech.idealled`, analyzed v3.0.4) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | BLE name prefix `IDL` |
| Passphrase protection | not_applicable |
| Confidence | medium (vendor-app analysis + open-source corroboration; not run in-repo) |

There is no provisioning: power the device, scan, connect, write. Commands are encrypted with
a fixed public key, so no key exchange is needed either.

**Factory reset**: there is no credential state to clear. Power-cycling drops the current
connection — the actual remedy for the common failure mode, which is the device already being
connected to another central (one link at a time).

**Rebinding to a new network**: not applicable — no network. Switching controllers is just
connecting from the new one. If the old controller was a phone, also remove the device from
the OS Bluetooth list so a cached bond doesn't keep reclaiming the link. After a firmware OTA
the device may reappear with its BLE address minus 1 LSB — rescan rather than reusing the old
address.

## Protocol Summary

Reverse engineered from the vendor app and corroborated by
[`8none1/idealLED`](https://github.com/8none1/idealLED) (HCI captures + working client).

### BLE Services

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Control service | — | Primary service; the scanner gate |
| `d44bc439-abfd-45a2-b575-925416129600` | Command | write | Encrypted 16-byte command blocks |
| `d44bc439-abfd-45a2-b575-925416129601` | Notification | notify | Encrypted acks (decrypt → ASCII) |
| `d44bc439-abfd-45a2-b575-925416129602` | Firmware version | read | Version bytes at [6],[7] after decrypt |
| `d44bc439-abfd-45a2-b575-92541612960a` | Bulk data | write | Fragmented multicolor/doodle/image payloads |
| `d44bc439-abfd-45a2-b575-92541612960b` | Auxiliary | write | Bound by the app; role not pinned down |
| `0000ae00-…` / `…ae01` / `…ae02` | JieLi OTA | write/notify | Standard JieLi RCSP OTA, `.ufw` images |

### Discovery

- Advertised name prefix `IDL`; the dependable signal is the `0xFFF0` service UUID.
- Manufacturer advertisement (AD type 0xFF) starts with `54 52 00 61` ("TR" + `0x0061`).
  Byte 6 = device group id, byte 7 = vendor/device id, bytes 11–12 = lamp count (uint16 LE).
- Some lights advertise as `IDL` or `ISP` but speak a **different** protocol (8none1) —
  confirm the service and characteristics before driving.

### Command Framing

Every command is a 16-byte block, AES-128-ECB encrypted (single block, no IV) with the static
family key published by `8none1/idealLED`:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Payload length (count of meaningful bytes that follow) |
| 1 | 4–9 | ASCII opcode + parameter bytes |
| rest | — | Zero padding |

### Commands (plaintext, before encryption)

| Opcode | Parameters | Description |
|--------|------------|-------------|
| `TURN` | 1B (01/00) | Power on/off |
| `LIGHT` | 1B | Brightness |
| `COLO` | 3B **G,R,B** (note order) | Solid color |
| `MODE` / `DIRECT` | 1B | Mode / effect-mode select |
| `SPEED` | 1B | Effect speed |
| `SGLS` | 1B index | Built-in effect; ack `SGLSOK` |
| `MULT` | model−10, !reverse, 100, speed, colorCount, saturation | Multicolor header; RGB triplets follow fragmented on the bulk channel; acks `MULTCPOK`/`MULTOK`/`MULTREOK` |
| `DOOD` | 2B index, mode, speed, R, G, B | Doodle/freehand pixel; completion `DOOTCP` |
| `SMVE` | `SMVEW 01` | Enter DIY mode |
| `ANIM` / `IMAG` | 1B index | Built-in animation/image select |
| `BEGU` / `PLAY` / `PLACP` / `MANCP` | 1B / — | Upload begin / play / transfer-complete markers |
| `CONNECT` | 7B | Post-connect handshake (payload undecoded) |
| `CHECKLINE` | 00/01 | Link check |
| `CONFIRM` | 2B ASCII (`G`=0x47, `B`=0x42, `R`=0x52) | RGB channel-order confirm |
| `LAMPQ` | — | Lamp-count query; reply `LAMPNMAX`+val or `LAMPNCANNOT` |
| `LEDS` / `LEDFIRST` / `LEDSECOND` | 1B / — | LED-count and daisy-chain config |

Bulk payloads fragment as `[chunk_len+1][frame_index][data…]` — 96-byte chunks with a
negotiated MTU, else 18.

Device replies arrive encrypted on the notify characteristic; after decryption they are
plaintext ASCII: `MULTOK`, `MULTCPOK`, `MULTREOK`, `SGLSOK`, `PLACPOK`, `PLAREOK`,
`LAMPNMAX`+value, `LAMPNCANNOT`, `ERROR`.

### OTA

Standard JieLi BLE OTA (service `0xAE00`, write `0xAE01`, notify `0xAE02`), firmware in the
JieLi `.ufw` container. The app bundles 14 product-keyed images and checks for updates via
`POST https://api.e-toys.cn/api/getFirmwareInfo`.

## Open Questions

- Exact post-connect handshake order (CONNECT / CHECKLINE / CONFIRM / LAMPQ) — needs one
  live capture.
- Whether bulk-channel (`…960a`) fragments are raw or ECB-encrypted (the sibling
  [Magic Display](magic-display.md) encrypts its bulk channel; the 96-byte fragment format
  here suggests raw).
- `SCHD` schedule layout, `MIC` music mode, `CAMERA` capture, and the `DEN`/`LEWPT` opcodes.
- Whether notify replies longer than 16 bytes are multi-block ECB.

## Tools Used

- [x] Static analysis of the vendor app (jadx)
- [x] Community open-source implementations (`8none1/idealLED`, `koying/ha_ideal_led_ble`)
- [ ] Live BLE capture against hardware (open)

## References

- [`8none1/idealLED` — key publication, HCI captures, protocol notes, HA integration](https://github.com/8none1/idealLED)
- [`koying/ha_ideal_led_ble` — second HA integration](https://github.com/koying/ha_ideal_led_ble)
- [Bricked-lights writeup](https://www.whizzy.org/2023-12-14-bricked-xmas/)
- [iDeal LED on Google Play](https://play.google.com/store/apps/details?id=com.tech.idealled)
- Sibling pages: [Magic Display](magic-display.md), [Shining Glasses](shining-glasses.md), [iDotMatrix](idotmatrix.md)
