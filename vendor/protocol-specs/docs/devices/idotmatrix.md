# iDotMatrix Pixel Display

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: iDotMatrix
> **Manufacturer Status**: Unsupported

## Overview

Small RGB pixel displays in 16x16 or 32x32 sizes. Supports static images, GIF animations, text, clock, countdown, and graffiti (pixel-by-pixel drawing). Cloud content library is optional.

## Hardware

| Property | Value |
|----------|-------|
| Display | 16x16 or 32x32 RGB LED matrix |
| Chipset | Unknown |
| Radio | BLE |
| FCC ID | Not documented |

## Protocol Summary

### BLE Characteristics

| UUID | Name | Properties |
|------|------|------------|
| `0000fa02-0000-1000-8000-00805f9b34fb` | Write Data | Write |
| `0000fa03-0000-1000-8000-00805f9b34fb` | Read Data | Read |

Device advertised name prefix: `"IDM-"`

### Commands

Variable-length bytearrays written to `0xFA02`.

| Command | Bytes | Description |
|---------|-------|-------------|
| Screen On | `05 00 07 01 01` | Turn display on |
| Screen Off | `05 00 07 01 00` | Turn display off |
| Freeze | `04 00 03 00` | Freeze/unfreeze display |
| Set Brightness | `05 00 04 80 VV` | Brightness 5-100% |
| Flip Screen | `05 00 06 80 VV` | 0=normal, 1=rotated 180 |
| Set Speed | `05 00 03 01 VV` | Animation speed |
| DIY Mode | `05 00 04 01 VV` | 0=disable, 1=enable image mode |
| Set Time | `0B 00 01 80 YY MM DD WW HH mm SS` | Set clock |
| Set Password | `08 00 04 02 01 HH MM LL` | 6-digit password |

### Framed Upload Protocol (recovered — com.tech.idotmatrix)

The recovered app (service `0xFEE9`, characteristic `d44bc439-…-925416129600`) sends
GIF / image / text as framed 4096-byte payload chunks, each prefixed by a 16-byte
header. This is the authoritative layout, derived from `GifAgreement.java` (see the
evidence report and the device-spec YAML, which use the same layout):

| Offset | Length | Field |
|--------|--------|-------|
| 0-1 | 2 | Total packet length (uint16, **big-endian**) |
| 2 | 1 | Command type: `1`=GIF, `2`=Image, `3`=Text/MultiColor, `6`=Phrase |
| 3 | 1 | Sub-type: `0x00`=data, `0x02`=MultiColor/Phrase |
| 4 | 1 | Chunk flag: `0x00`=first, `0x02`=continuation |
| 5-8 | 4 | Total data length (uint32, **little-endian**) |
| 9-12 | 4 | CRC32 of the entire data payload (`java.util.zip.CRC32`, **little-endian**) |
| 13-14 | 2 | Time/delay (uint16, **big-endian**) |
| 15 | 1 | Speed/type byte |
| 16+ | var | Payload (image / GIF / text data) |

For a GIF chunk, bytes `[2..3]` are therefore `0x01 0x00`; for an image, `0x02 0x00`.
Each chunk is written with acknowledgment (`response=True`). BLE chunking: 509 bytes
when MTU is negotiated, else 18; 20 ms/chunk for GIF/image, 50 ms/chunk for text.
The exact image pixel encoding (RGB565, laid out per device type) is **MEDIUM**
confidence and needs live-capture confirmation.

> The `0xFA02` byte commands in the **Commands** table above belong to the legacy /
> community `python-idotmatrix` protocol (service `0xFA02`). A given unit speaks either
> the framed `0xFEE9` protocol documented here or the legacy `0xFA02` one; the device
> spec YAML documents both.

## Tools Used

- [x] APK decompilation
- [x] Community open-source implementations

## References

- [derkalle4/python3-idotmatrix-library](https://github.com/derkalle4/python3-idotmatrix-library) (archived)
- [8none1/idotmatrix](https://github.com/8none1/idotmatrix)
- [markusressel/idotmatrix-api-client](https://github.com/markusressel/idotmatrix-api-client)

## Contributors

- @derkalle4 -- Python library (original)
- @8none1 -- alternative implementation
- @markusressel -- API client
