# Magic Display

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: tirohk / AiTURE
> **Manufacturer Status**: Abandoned

## Overview

Bluetooth-controlled LED displays for shoes, bags, hats, and crafts. Uses a Quintic (NXP QN-series) BLE chipset with QPP (Quintic Private Profile). All traffic is AES-128 encrypted via native `libAES.so`. Shares the same BLE UUIDs as Shining Mask/Glasses (both use the Quintic QPP platform) but has a distinct command set and device identification.

## Hardware

| Property | Value |
|----------|-------|
| Display | Monochrome LED matrix (5x36, 12x48, 14x56, or 16x64) |
| Chipset | Quintic (NXP QN-series) |
| Radio | BLE |
| FCC ID | Unknown |
| Max connections | 6 simultaneous devices |

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000fee9-0000-1000-8000-00805f9b34fb` | QPP Service | Primary BLE service (Quintic Private Profile) |
| `0000fee8-0000-1000-8000-00805f9b34fb` | OTA Service | Firmware update (Quintic OTA protocol) |

### Characteristics

| UUID | Name | Properties | Purpose |
|------|------|------------|---------|
| `d44bc439-abfd-45a2-b575-925416129600` | Command (WRITE1) | Write | AES-encrypted 16-byte commands |
| `d44bc439-abfd-45a2-b575-925416129601` | Notification | Notify | Device responses (STYPE, DATSOK, etc.) |
| `d44bc439-abfd-45a2-b575-92541612960a` | Bulk Data (WRITE2) | Write | Image/text bitmap frames |
| `d44bc439-abfd-45a2-b575-92541612960b` | Auxiliary (WRITE3) | Write | Additional data channel |

### Encryption

- **Algorithm**: AES-128 via native `libAES.so` (`keyExpansionDefault()`)
- **Mode**: ECB with fixed default key in native binary
- **All** commands encrypted before write; responses decrypted on receive
- Key must be extracted from `libAES.so` binary to interoperate

### Device Discovery

Identified by manufacturer-specific advertising data (not by name):

- AD type `0xFF`, payload starts with `{0x54, 0x52, 0x00, 0x27}` ("TR" + 0x0027)

### Commands

All commands are 16-byte fixed-length packets (plaintext, before AES encryption). Format: `[length, ASCII_CMD..., params..., zero_pad_to_16]`.

| Command | Bytes (plaintext) | Description |
|---------|-------------------|-------------|
| STYPE | `[5, 'S','T','Y','P','E']` | Query display dimensions |
| LEDON | `[5, 'L','E','D','O','N']` | Turn display ON |
| LEDOFF | `[6, 'L','E','D','O','F','F']` | Turn display OFF |
| LIGHT n | `[6, 'L','I','G','H','T', n]` | Set brightness |
| SPEED n | `[6, 'S','P','E','E','D', n]` | Set animation speed |
| MODE 1 | `[5, 'M','O','D','E', 1]` | Static display |
| MODE 2 hi lo | `[7, 'M','O','D','E', 2, hi, lo]` | Flash (ms, big-endian) |
| MODE 3 n | `[6, 'M','O','D','E', 3, n]` | Scroll left |
| MODE 4 n | `[6, 'M','O','D','E', 4, n]` | Scroll right |
| MODE 7 | `[5, 'M','O','D','E', 7]` | Rhythm/music mode |
| EVERT | `[5, 'E','V','E','R','T']` | Invert/flip display |
| ANIM n | `[5, 'A','N','I','M', n]` | Select animation frame |
| TIME h m s | `[7, 'T','I','M','E', h, m, s]` | Set device clock |
| SCHD on h m | `[7, 'S','C','H','D', on, h, m]` | Timer auto-off schedule |
| CALL s t | `[6, 'C','A','L','L', status, time]` | Phone call notification |

### Data Transfer Protocol

1. **DATS** on WRITE1: `[8, 'D','A','T','S', len_hi, len_lo, 0, link_flag]`
2. Device responds **DATSOK** on notify
3. Send data chunks on WRITE2: `[payload_len, ...data]` (16 bytes each, 50-60ms delay)
4. **DATCP** on WRITE1: `[5, 'D','A','T','C','P']`
5. Device responds **DATCPOK** on notify

### Display Types

Reported via STYPE response after connection:

| Type | Grid (WxH) | Bitmap bytes | Notes |
|------|------------|-------------|-------|
| STYPE5X36 | 5 x 36 | 36 | 1 byte/col, 5 bits used |
| STYPE5X36N | 5 x 72 | 72 | Two linked 5x36 |
| STYPE12X48 | 12 x 48 | 72 | Column-pair encoding |
| STYPE12X48N | 12 x 96 | 144 | Two linked 12x48 |
| STYPE16X64 | 16 x 64 | 128 | 2 bytes/col (rows 0-7, 8-15) |

### Bitmap Encoding

Monochrome, 1-bit-per-pixel (any RGB channel >= 128 = ON):

- **5x36**: 1 byte per column, bits 4-0 = rows 0-4
- **12x48**: Column pairs produce 3 bytes per pair (packed 12-bit rows)
- **16x64**: 2 bytes per column, byte 0 = rows 0-7 (bits 7-0), byte 1 = rows 8-15

### Connection Sequence

1. Connect, `requestConnectionPriority(HIGH)`
2. Discover services, find `0xFEE9`
3. Enable notifications on `...9601`
4. Send `LEDFIRST` or `LEDSECOND` (multi-device position)
5. Wait 200ms, send `TIME` with current time
6. Wait 200ms, send `STSC` (read timer schedule)
7. Device responds with `STYPE` identifying display resolution

## Tools Used

- [x] APK decompilation (jadx)
- [ ] HCI snoop capture (pending)
- [ ] Native library (libAES.so) key extraction (pending)

## References

- [Google Play: Magic Display](https://play.google.com/store/apps/details?id=com.tirohk.magicdisplay)

## Contributors

- APK static analysis (jadx decompilation)
