# Shining Mask

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: Shenzhen Shining Bright Technology
> **Manufacturer Status**: Unsupported

## Overview

RGB LED face mask with 2074 LEDs in a 46x58 irregular layout. Protocol uses AES-128 ECB encryption with a fixed key. No authentication -- anyone in BLE range can control the mask.

## Hardware

| Property | Value |
|----------|-------|
| LED Count | 2074 RGB LEDs (2121 package) |
| Display | 16 pixels tall, variable width |
| Chipset | Unknown |
| Radio | BLE |
| FCC ID | 2AOLN-16 |

## Protocol Summary

### BLE Characteristics

| UUID | Name | Properties | Encrypted |
|------|------|------------|-----------|
| `d44bc439-abfd-45a2-b575-925416129600` | Command | Write | Yes (AES-128 ECB) |
| `d44bc439-abfd-45a2-b575-925416129601` | Notification | Notify | Yes (AES-128 ECB) |
| `d44bc439-abfd-45a2-b575-92541612960a` | Image Upload | Write | No (raw bytes) |
| `d44bc439-abfd-45a2-b575-92541612960b` | Audio Visualizer | Write | Yes (AES-128 ECB) |

Scan filter service UUID: `0000FFF0-0000-1000-8000-00805F9B34FB`

### Commands (pre-encryption, padded to 16 bytes)

Format: `[length] [ASCII command name] [arguments...] [padding]`

| Command | Plaintext | Description |
|---------|-----------|-------------|
| LIGHT | `06 4C494748 54 VV` | Set brightness (0x00-0xFF) |
| MODE | `05 4D4F4445 VV` | 0=off, 1=steady, 2=blink, 3=scroll R-L, 4=scroll L-R |
| SPEED | `06 53504545 44 VV` | Set animation speed |
| IMAG | `05 494D4147 VV` | Show built-in image (0x00-0x69) |
| ANIM | `05 414E494D VV` | Play built-in animation (0x00-0x45) |
| FC | `06 4643 01 RR BB GG` | Set foreground color (R,B,G order) |
| BC | `06 4243 01 RR BB GG` | Set background color (R,B,G order) |

### Image Upload Protocol

1. Send `DATS` command (encrypted) with total size and bitmap size
2. Receive `DATOK` notification
3. Send data packets to Image Upload characteristic (unencrypted, max 100 bytes: `[len][counter][data...]`)
4. Receive `REOKOK` per packet
5. Send `DATCP` command (encrypted) with Unix timestamp
6. Receive `DATCPOK`

### Bitmap Encoding

Each column is 5 bytes: `[row_bitmask_low] [row_bitmask_high] [R] [G] [B]`. Color is per-column, not per-pixel.

## Tools Used

- [x] Community open-source implementations

## References

- [GoneUp/mask-go](https://github.com/GoneUp/mask-go)
- [Bishop Fox blog](https://bishopfox.com/blog/invasion-of-the-face-changers-halloween-hijinks-with-bluetooth-led-masks)
- [BishopFox/shining-mask](https://github.com/BishopFox/shining-mask)
- [BrickCraftDream/Shining-Mask-stuff](https://github.com/BrickCraftDream/Shining-Mask-stuff)

## Contributors

- @GoneUp -- Golang implementation
- Bishop Fox -- security research
- @shawnrancatore -- CircuitPython implementation
