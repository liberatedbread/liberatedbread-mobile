# CoolLEDX / CoolLED1248 LED Signs

> **Status**: In Progress
> **Protocol**: BLE
> **Manufacturer**: Juntong Technology (believed)
> **Manufacturer Status**: Unsupported

## Overview

The single most common cheap BLE LED sign family on AliExpress, Amazon and Temu — sold with no
brand name, only a product-page screenshot of the **CoolLED1248** app. They turn up as car rear-window
signs, bike/backpack panels, name badges, bar signs and hat visors. Sizes vary from 12×48 up to
long banner strips; color capability varies from monochrome through a 7-color mode to full RGB.

The app is a pixel design tool: type text with a color picker, drop in an image or animated GIF,
or drive a music-reactive bar visualizer. The design is rendered on the phone and pushed to the
sign as a bitmap.

There are at least seven hardware generations sharing the `CoolLED*` advertising name. Only the
`CoolLEDX` generation ("basic protocol") is fully mapped; `CoolLEDM` and later use an "advanced
protocol" that is largely unmapped, with a nearly identical frame structure but different command
values.

## Hardware

| Property | Value |
|----------|-------|
| Advertised names | `CoolLED`, `CoolLEDA`, `CoolLEDX`, `CoolLEDS`, `CoolLEDM`, `CoolLEDU`, `CoolLEDUD` / `iLedBike`, `CoolLEDMX`, `CoolLEDUX` |
| Radio | BLE |
| Sizes | Variable; `CoolLED` fixed 48×12, `CoolLEDA` fixed 32×16, `CoolLEDX` variable (96×16 typical) |
| Color modes | `0x00` monochrome, `0x01` 7-color, `0x02` full RGB |
| App | CoolLED1248 (iOS / Android) |

## Protocol Summary

### Discovery

Scan for a device whose local name starts with `CoolLED` (or is `iLedBike`) to *recognise* the
family. Match on the **exact** name to decide what to drive: only `CoolLEDX` is mapped, and the
device spec deliberately restricts auto-discovery to it. A `CoolLEDM`/`CoolLEDU`/`CoolLEDMX`/
`CoolLEDUX` that matched a loose `CoolLED` prefix would be handed the basic-protocol command
table, which is silently wrong on those generations.

**The advertisement carries the panel geometry**, so a client never has to ask the user for the
sign's size:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 6 | MAC address |
| 6 | 1 | Height (pixels) |
| 7 | 2 | Width (pixels, uint16 BE) |
| 9 | 1 | Color mode (0 = mono, 1 = 7-color, 2 = full RGB) |
| 10 | 1 | Firmware version |

Manufacturer data shorter than 11 bytes means the device is not a usable `CoolLED*`.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Control Service | Primary service |
| `0000fff1-0000-1000-8000-00805f9b34fb` | Control | Write commands, receive notifications |

### Frame Format (basic protocol — CoolLEDX)

```
0x01 | escape( length_be16 || payload ) | 0x03
```

- `0x01` start-of-frame, `0x03` end-of-frame
- `length_be16` is the unescaped payload length, big-endian, and **is itself escaped**
- payload is `[command byte][command data...]`

Because `0x01` and `0x03` are frame delimiters, any byte below `0x04` inside the length or
payload is escaped with a `0x02` prefix and offset by `+4`:

| Raw | Escaped |
|-----|---------|
| `0x00` | `0x02 0x04` |
| `0x01` | `0x02 0x05` |
| `0x02` | `0x02 0x06` |
| `0x03` | `0x02 0x07` |

Escape `0x02` first when transforming a buffer, or you will double-escape the escape prefixes
you just introduced.

### Commands

| Command | Byte | Notes |
|---------|------|-------|
| Music bars | `0x01` | 16 bytes on CoolLEDX (8 heights + 8 colors); 8 bytes on CoolLEDM |
| Text | `0x02` | Rendered text bitmap payload |
| Image | `0x03` | Still image bitmap payload |
| Animation | `0x04` | Multi-frame payload |
| Icon | `0x05` | Icon payload |
| Mode | `0x06` | Display mode |
| Speed | `0x07` | `0x00`–`0xFF` |
| Brightness | `0x08` | `0x00`–`0xFF` |
| Switch | `0x09` | Power/app on-off |
| Transfer | `0x0A` | Unconfirmed |
| Invert display | `0x0C` | Confirmed on CoolLEDM |
| Clear (probable) | `0x0D` | Observed on CoolLEDM followed by `28 28 28 28 28 28 28 00` |
| Show icon | `0x11` | Unconfirmed |
| Power down | `0x12` | Unconfirmed |
| Button on | `0x13` | Unconfirmed |
| Mirror (probable) | `0x15` | Unconfirmed |
| Query | `0x1F` | CoolLEDM replies `01 ff 00 01 00` |
| Initialize | `0x23` | Takes a battery level byte; confirmed on CoolLEDM |

Text, image and animation payloads are rendered client-side to the panel's advertised
width/height and color mode before being chunked into frames.

### Error Codes

| Code | Meaning |
|------|---------|
| `0x00` | Success |
| `0x01` | Transmission failed |
| `0x02` | Device abnormality |
| `0x03` | Data error |
| `0x04` | Data length error |
| `0x05` | Data ID error |
| `0x06` | Data checksum error |

### CoolLEDM and later ("advanced protocol")

Same `0x01` / `0x03` framing and `0x02` escaping, but nearly every command value differs and the
text/image payload encodings are opaque. Newer app versions (2.x) can import/export a `.JT` design
file, which is a useful bridge for building content without speaking the wire protocol.
**This generation is not yet mapped and is the main open item on this target.**

## Open Questions

- Advanced-protocol command table for `CoolLEDM` / `CoolLEDU` / `CoolLEDUX`.
- Whether newer generations require password verification before accepting commands.
- `.JT` file format specification.

## Tools Used

- [x] Community open-source implementations (`coolledx-driver`)
- [x] Android BLE HCI snoop (upstream methodology)
- [ ] Independent capture against a CoolLEDM-class sign (pending)

## References

- [`coolledx-driver` — Python driver for CoolLED1248 signs](https://github.com/UpDryTwist/coolledx-driver)
- [`coolledx` on PyPI](https://pypi.org/project/coolledx/)

## Contributors

- @UpDryTwist -- `coolledx-driver`, CoolLEDX protocol documentation
- CrimsonClyde -- original CoolLEDX reverse engineering (LED FaceShields)
