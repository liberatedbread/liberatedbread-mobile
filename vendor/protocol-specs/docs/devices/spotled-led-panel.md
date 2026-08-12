# SPOTLED LED Panels

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: Host No.4 Technology (Chengdu) Co., Ltd. / generic OEM
> **Manufacturer Status**: Unsupported

## Overview

SPOTLED is an OEM design app for wearable full-color LED matrix panels, claiming 140,000+ users.
It is not tied to any one brand: the same app drives LED hats, name badges, backpack and
hydration-pack skins, chest panels and long flexible banner signs (32×256 arrays are commonly
sold), all rebranded by different resellers.

It is a genuine design tool rather than an effect picker — full-color text with fonts and scroll
effects, freehand "graffiti" drawing, still image upload, animated GIF upload and a music-rhythm
visualizer. Content is rendered on the phone and uploaded to the panel as bitmap frames.

This page is the **canonical SPOTLED protocol reference**. Products that use it include the
[Lunchbox / LEDs 2 RAVE 4 Dream Skin](leds2rave4-lunchbox-led.md) 2.0 and early 3.0 panels,
which document their own generation/app mapping separately.

Devices are connected from inside the app rather than through system Bluetooth pairing, and there
is no bonding — anything in range can drive the panel.

## Hardware

| Property | Value |
|----------|-------|
| Display | Full-color or monochrome LED matrix; geometry varies by product |
| Geometry source | Reported by the device via `GetDisplayInfo` — **do not hardcode** |
| Color depth | `16` monochrome, `255` RGB (as reported by `GetDisplayInfo`) |
| Radio | BLE |
| Pairing | None — no bonding, no auth |
| App | SPOTLED (`com.led.spotled` Android, App Store id 1564039607) |

## Protocol Summary

Reverse engineered independently by [`python-spotled`](https://github.com/iwalton3/python-spotled)
via BLE sniffing.

### BLE Services

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `0000ff20-0000-1000-8000-00805f9b34fb` | SPOTLED Service | — | Primary service |
| `0000ff21-0000-1000-8000-00805f9b34fb` | Command | write, notify | Control commands + responses |
| `0000ff22-0000-1000-8000-00805f9b34fb` | Data | write | Bulk payload channel |

### Discovery

There is no reliable advertised-name prefix across the family — resellers set their own. The
`0000ff20` service is the dependable signal. Known product-specific names include
`LBXDRMSKIN_LED_` (Lunchbox Dream Skin).

### Connection Bootstrap

1. Connect and negotiate MTU (falls back to 23 if not negotiated).
2. Enable notifications by writing `00 00 00 01` to the CCCD (handle `0x0F` on observed units).
3. Discover the `0xFF21` command and `0xFF22` data handles under service `0xFF20`.
4. Issue `GetBufferSize` — required, it determines the upload chunking cadence.
5. Issue `GetDisplayInfo` — gives width, height, color depth, frame limit and current brightness.

Steps 4 and 5 are not optional for a working client: chunk pacing and content rendering both
depend on their results.

### Command Frame (write to `0xFF21`)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Frame length |
| 1 | 1 | Command ID |
| 2 | 2 | Serial number (uint16 BE, wraps at `0xFFFF`) |
| 4 | 2 | Command type (uint16 BE) |
| 6 | 4 | Command length (uint32 BE) |

| Command | ID | Frame length | Description |
|---------|----|--------------|-------------|
| SendingDataStart | `0x01` | 10 | Announce an incoming data payload |
| SendingDataFinish | `0x03` | 10 | Payload fully transmitted |
| GetVersion | `0x10` | 4 | Device type, device revision, software revision |
| GetDisplayInfo | `0x12` | 4 | Width, height, color depth, frame limit, brightness, font info |
| GetBufferSize | `0x14` | 4 | Device data buffer size |

The three `Get*` commands are 4-byte frames: `[04] [id] [00] [00]`.

### Data Frame (write to `0xFF22`)

Payloads carry a 15-byte header followed by one or more typed content records:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 4 | Header length (always 15) |
| 4 | 2 | Command type (`0x8004` for data) |
| 6 | 4 | Serial number (uint32 BE, wraps at `0xFFFFFFFF`) |
| 10 | 4 | Content length (uint32 BE) |
| 14 | 1 | Checksum |
| 15+ | varies | Content records |

**Checksum**: sum the covered bytes; if the total exceeds `0xFF`, negate it (`(~sum) + 1`); keep
the low byte.

### Content Record Types

Each record is `[uint32 length][uint16 type][fields…][checksum]`.

| Type | Name | Payload |
|------|------|---------|
| `2` | Color | RGB color entry |
| `3` | Character | Single unicode codepoint |
| `4` | Text | Char count, per-char glyph + color, trailing effect record |
| `5` | Font | Count + font character glyphs |
| `7` | Time | Per-frame display time (used only when no effect is set) |
| `8` | Effect | Display mode |
| `9` | Speed | Animation speed |
| `10` | NumberBar | Music-visualizer bar heights |
| `11` | Animation | Frame count (max 20) + frames + time + speed + effect |
| `13` | FontCharacter | Width, height, codepoint, glyph bitmap |
| `14` | Brightness | 0–100 |
| `15` | ScreenMode | 0 normal, 1 upside-down, 2 mirror, 3 mirror + upside-down |
| `96` | Frame | Width, height, color depth (1 mono / 24 RGB), bitmap |

Effects (type `8`): `0` none, `1` scroll up, `2` scroll down, `3` scroll left, `4` scroll right,
`5` stack, `6` expand, `7` laser.

Text can be sent two ways. Rendering it client-side into an **Animation** (type `11`) of frames is
faster and more capable; sending it as **Character** records (type `3`, capped around 72 chars)
lets the device lay it out but is slower and more limited. Custom glyphs must be uploaded as
`FontCharacter` records before the text that references them.

### Upload Flow Control

Uploads are gated by the device, and getting this wrong is the most common failure mode.

1. Send `SendingDataStart` with the payload length. Expect a `SendingData` response whose serial
   number, command type and zero error code all match.
2. Write the payload to `0xFF22` in chunks of **`MTU − 3`** bytes.
3. After every **`buffer_size ÷ chunk_size`** chunks — i.e. once the device's buffer is full —
   wait for a `ContinueSending` notification and **resume from the byte offset it returns**,
   rather than from your own cursor. (The upstream implementation notes this as roughly every
   6 data commands; the computed value is authoritative.)
4. Send `SendingDataFinish` and wait for the final response.

| Response | Type | Meaning |
|----------|------|---------|
| SendingData | `2` | Serial number + error code + command type |
| ContinueSending | `255` | Buffer drained; resume from the returned offset |
| PauseSending | — | Read error — almost always a bad MTU |
| DisplayInfo | — | `width`, `height`, `color_depth`, `frame_limit`, `brightness`, `font_info` |
| Version | — | `device_type`, `device_revision`, `software_revision` |
| BufferSize | — | `buffer_size` |

!!! warning "MTU"
    `PauseSending` fires when chunks are too large **or too small**. A client that assumes the
    23-byte default while the device negotiated something larger, or vice versa, produces
    truncated uploads that look like data corruption. Derive the chunk size from the negotiated
    MTU every connection.

## Open Questions

- Whether SPOTLED and [iLEDColor](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/targets/iledcolor-led-panel.md)
  panels share this protocol. New Lunchbox DreamPanel v3 boards moved to iLEDColor; probing one
  for the `0xFF20` service is the cheapest possible test.
- CCCD handle `0x0F` is observed, not guaranteed — discover it properly rather than hardcoding.
- Colour `Frame` records (depth 24) are implemented upstream but were never tested against RGB
  hardware by the original author.

## Tools Used

- [x] Community open-source implementations (`python-spotled`)
- [x] BLE sniffing (upstream methodology)

## References

- [`python-spotled` — reverse-engineered SPOTLED BLE library](https://github.com/iwalton3/python-spotled)
- [`spotled` on PyPI](https://pypi.org/project/spotled/)
- [Google Play — SPOTLED](https://play.google.com/store/apps/details?id=com.led.spotled)
- [App Store — SPOTLED](https://apps.apple.com/us/app/spotled/id1564039607)
- [Lunchbox Packs — Dream LED Skin 2.0 setup (SPOTLED)](https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0)

## Contributors

- @iwalton3 -- `python-spotled`, SPOTLED BLE protocol reverse engineering
