# Shining Glasses

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: Shenzhen Shining Bright Technology (cdbwsoft/icwork)
> **Manufacturer Status**: Abandoned

## Overview

Bluetooth-controlled LED glasses. Uses **identical protocol** to [Shining Mask](shining-mask.md) — same UUIDs, AES encryption, ASCII-based 16-byte command format, and DATS/DATCP data transfer handshake. Both products share the `com.cdbwsoft.library.ble` SDK.

## Hardware

| Property | Value |
|----------|-------|
| Display | LED matrix (5x36, 12x48, or 16x64 depending on variant) |
| Chipset | Quintic (NXP QN-series) or Panchip |
| Radio | BLE |
| FCC ID | Unknown |

## Protocol Summary

### BLE Services

| UUID | Name |
|------|------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Scan filter / advertisement service |

### Characteristics

| UUID | Name | Properties | Purpose |
|------|------|------------|---------|
| `d44bc439-abfd-45a2-b575-925416129600` | Command (WRITE1) | Write | AES-encrypted 16-byte commands |
| `d44bc439-abfd-45a2-b575-925416129601` | Notification | Notify | Device responses (DATSOK, DATCPOK, STYPE, etc.) |
| `d44bc439-abfd-45a2-b575-92541612960a` | Image Upload (WRITE2) | Write | Bulk data frames (text bitmaps, images) |
| `d44bc439-abfd-45a2-b575-92541612960b` | Audio/DIY (WRITE3) | Write | Real-time pixel data, rhythm/audio FFT |

### Encryption

- **Algorithm**: AES-128 (native `libAES.so`, `keyExpansionDefault()`)
- **Mode**: ECB, fixed default key baked into native library
- **Block size**: 16 bytes (all commands are exactly 16 bytes)
- **Key**: Same as Shining Mask (see [GoneUp/mask-go](https://github.com/GoneUp/mask-go) for published key)

### Device Discovery

Devices are identified by **manufacturer-specific advertising data**, not by name prefix:

- AD type `0xFF`, payload starts with `{0x54, 0x52, 0x00, 0x41}` ("TR" + 0x0041)

### Commands

See [Shining Mask](shining-mask.md) for full command table — protocol is identical. Key commands:

| Command | Plaintext bytes | Description |
|---------|----------------|-------------|
| Set brightness | `[0x06, 'L','I',0x47,0x48,'T', level]` | Set LED brightness |
| Set speed | `[0x06, 'S','P','E','E',0x44, speed]` | Set scroll/animation speed |
| Select animation | `[0x05, 'A',0x35,'I',0x34, index]` | Play built-in animation |
| Select image | `[0x05, 'I',0x34,'A',0x47, index]` | Show built-in image |
| Set FG color | `[0x06, 'F','C', flag, R, G, B]` | Set text foreground color |
| Set BG color | `[0x06, 'B','C', flag, R, G, B]` | Set text background color |
| Enter DIY mode | `[0x06, 'S',0x34,'V','E','W', 1]` | Single-frame DIY drawing |
| Exit DIY (save) | `[0x06, 'S',0x34,'V','E','W', 2]` | Save and exit DIY |
| Play DIY | `[0x04, 'P','L','A','Y']` | Play saved DIY animation |

### Data Transfer Protocol

1. **DATS** → device on WRITE1: `[0x09, 0x44,'A','T','S', len_hi, len_lo, datalen_hi, datalen_lo, type]`
2. Device responds **DATSOK** on notify
3. Send data frames on WRITE2: `[payload_len+1, frame_index, ...data]` (18 or 98 bytes per frame)
4. Device responds **REOK** per frame
5. **DATCP** → device on WRITE1: `[0x05, 0x44,'A','T','C','P']`
6. Device responds **DATCPOK**

### Display Sizes

| Code | Grid | Notes |
|------|------|-------|
| 536 | 5 x 36 | Small badge variant |
| 1248 | 12 x 48 | Medium display |
| 1664 | 16 x 64 | Primary glasses mode |

## Tools Used

- [x] APK decompilation (jadx) -- confirmed protocol identity with Shining Mask
- [ ] HCI snoop capture (pending)

## References

- [Google Play: Shining Glasses](https://play.google.com/store/apps/details?id=com.icwork.shiningglass)
- [GoneUp/mask-go](https://github.com/GoneUp/mask-go) (Shining Mask RE -- same protocol)
- [gsuberland/ChemionHacking](https://github.com/gsuberland/ChemionHacking) (analogous LED glasses RE)

## Contributors

- APK static analysis (jadx decompilation)
