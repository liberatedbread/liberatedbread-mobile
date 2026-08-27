# Ignis Pixel LED Flow-Arts Props

> **Status**: In Progress
> **Protocol**: BLE (Nordic UART Service)
> **Manufacturer**: Ignis Pixel
> **Manufacturer Status**: Active (protocol unpublished; firmware distributed publicly)

## Overview

[Ignis Pixel](https://ignispixel.com/) makes programmable LED flow-arts props — pixel
poi, staffs, fans, buugeng, hoops, clubs, juggling props, jumpropes and lamps. You
upload images or timelines from the companion app (`com.ignispixel`, Android/iOS) or
the desktop Ignis Pixel Utility, and the prop renders them as persistence-of-vision
pictures while spun. The vendor's public firmware catalog lists ~137 device types.

The vendor is in business and updates the app and firmware regularly — the catch for
longevity is that the BLE protocol is unpublished and the app's content library is
cloud-fed. The good news: **the entire firmware catalog and the desktop updater are
public, unauthenticated HTTPS downloads**, and the BLE transport, framing and message
format are mapped. What is still missing is the numeric command-opcode table, so a
third-party client cannot quite be built from today's notes alone — see
[Open Questions](#open-questions).

## Hardware

| Property | Value |
|----------|-------|
| Models | ~137 device types: poi, staffs, fans, hoops, clubs, jumpropes, lamps ("iPixel" line) |
| Main MCU | STM32F103 / STM32F411 |
| BLE | nRF52832 running a Nordic UART Service bridge |
| Pixels | WS2812 |
| Sync radio | nRF24L01+ 2.4 GHz (Wireless Sync "I" models only; prop-to-prop, not BLE) |
| Companion app | `com.ignispixel` (Android, Qt6/QML), iOS equivalent, desktop Ignis Pixel Utility |

Device families (the `FW_DevType` the prop reports, matching the `Type=` attribute in
the firmware catalog): `0x04xx` classic poi · `0x05xx`/`0x06xx` gen2 props (NG poi,
hoops, fans, buugeng, staff) · `0x07xx` gen3 "toys" (BubblePoi/JellyPoi, sticks,
clubs, cubes) · `0x0Axx` jumpropes · `0x25xx`–`0x2Axx` "I" models with the internal
sync radio.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Advertised name not yet captured; scan for the Nordic UART Service UUID |
| Passphrase protection | not_applicable |
| Confidence | medium (app analysis; no live capture yet) |

Power the prop on and it advertises over BLE immediately — no account, no pairing, no
app-mediated onboarding. The vendor app's own scanner looks for the Nordic UART
Service UUID (`6e400001-…`) and nothing else.

!!! warning "The NUS UUID is not unique to Ignis Pixel"
    The Nordic UART Service is a stock platform UUID used by countless UART-bridge
    gadgets. After connecting, confirm you are really talking to an Ignis Pixel prop
    by issuing the get-id / hardware-info request and checking the reported device
    type — do not trust the advertisement alone.

**Factory reset**: there is no pairing or credential state to clear. Power-cycling
drops the current connection — which is also the fix for the most common failure
mode, the prop still being connected to another phone. Radio-sync settings
(channel/group) live on the prop and are changed from its own system menu, not wiped
over BLE. If the prop no longer boots (e.g. an interrupted firmware update), recovery
is a reflash with the vendor's public desktop utility and the release `.fw` file for
your exact model — both linked under [References](#references).

**Rebinding to a new controller**: just connect from the new phone — nothing binds a
prop to an owner. Remove the prop from the old phone's OS Bluetooth list if it keeps
grabbing the link. One caveat: a prop switched into RF slave mode (Wireless Sync)
stops accepting BLE control until it is power-cycled, unless its radio mode was
saved.

## Wireless Sync (prop-to-prop)

Models with the Wireless Sync option carry an nRF24 radio that syncs whole groups of
props — one prop acts as controller and the rest follow. Per the vendor FAQ there are
**13 radio channels × 32 groups**; props that share a channel and group stay in sync,
and different channels/groups run independently. Configuration happens on the prop
itself: hold the UP+DOWN buttons for 5 seconds to enter the system menu, where menu
point 2 selects the channel and point 3 the group (the app exposes the same settings
through its RF-configuration commands). This link is **not BLE** and its on-air
protocol is unmapped.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART Service | Sole transport service |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | NUS RX | Phone → device, written **with** response |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | NUS TX | Device → phone notifications (enable via CCC `0x2902`) |

### Framing and message format

Every packet on either characteristic:

```
0xFF                                  start marker
payload (each 0xFF byte sent as FF FE) escaped body
0xFF 0xFF                             end marker
```

There is no length field — a received packet is complete when the stream ends in
`FF FF`. The unescaped payload begins with an 8-byte header:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Message type ID |
| 1 | 4 | Time (uint32 LE) |
| 5 | 2 | CRC-16/CCITT (poly 0x1021, init 0, no final XOR; computed with this field zeroed) |
| 7 | 1 | Reserved (1 in phone→device requests — unconfirmed) |

Phone→device requests are 13 bytes: command ID at offset 8, one uint32 LE argument at
offsets 9–12, CRC filled in, then framed. Bulk data (images, firmware) rides in
blocks protected by a separate CRC32. The device answers with one of ~21 typed
message structs (ACK, device/hardware info, journal data, …); the hardware-info reply
reports MCU/radio/IMU types, battery level, firmware version (packed uint32, e.g.
`0x03002100` = v3.0.33) and the device-type ID used in the family table above.

### Commands

About 70 command names are recovered — brightness, display modes (ball, creeping
line, swing, volchok, player), alarms and off-timer, system settings (run-on-start,
stillness dimming, sensor), training journal, image upload/erase, RF sync
configuration and group actions, and the firmware-update sequence
(go-to-bootloader → erase → CRC32-protected blocks → return-to-main). **The numeric
opcode bytes are not yet extracted** — the command entries in the machine-readable
spec are symbolic placeholders. See `device-specs/devices/ignis-pixel.yaml` for the
full vocabulary.

## Open Questions

- **Numeric opcode map** — the one blocker for a working third-party client. The
  constants sit next to the command-name strings in the app's native code; a scripted
  extraction pass is planned.
- NUS write chunking / MTU behavior for large image and firmware transfers.
- Exact image-block and extended-command field layouts; whether `.fw` files are
  obfuscated.
- On-air protocol of the nRF24 sync link.
- Advertised BLE local name (never captured — record it on first hardware contact).

## Tools Used

- [x] APK static analysis (the app's protocol logic is native; disassembled with full symbols)
- [x] Live firmware-server catalog harvest (Update.xml, hash.md5)
- [ ] HCI snoop of a live prop (pending)

## References

- [Ignis Pixel firmware catalog — Update.xml](https://software-upload.ignispixel.com/Update/Update.xml)
- [File manifest — hash.md5](https://software-upload.ignispixel.com/Update/hash.md5)
- [Ignis Pixel Utility, desktop updater (Windows)](https://software-upload.ignispixel.com/Update/Software/IgnisPixelUtility_Win.exe)
- [Ignis Pixel FAQ — Wireless Sync and recovery](https://ignispixel.com/faq/support)
- [Ignis Pixel downloads (manuals, software, picture sets)](https://ignispixel.com/downloads)
- [Ignis Pixel on Google Play](https://play.google.com/store/apps/details?id=com.ignispixel)

## Contributors

- Liberated Bread research — app analysis and protocol recovery
