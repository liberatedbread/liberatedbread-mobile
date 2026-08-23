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
| Max connections | 6 simultaneous devices (app-side limit, `AppConfig.MAX_CONNECTED_DEVICE`) |

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
| `d44bc439-abfd-45a2-b575-92541612960a` | Bulk Data (WRITE2) | Write | Image/text bitmap frames (AES-encrypted 16-byte blocks) |
| `d44bc439-abfd-45a2-b575-92541612960b` | Auxiliary (WRITE3) | Write | Live DIY pixel writes and music/rhythm level frames (AES-encrypted 16-byte packets) |
| `013784cf-f7e3-55b4-6c4c-9fd140100a16` | OTA Write (on `0xFEE8`) | Write | Quintic OTA meta/data/verify/exec, 256-byte packets, unencrypted |
| `003784cf-f7e3-55b4-6c4c-9fd140100a16` | OTA Notify (on `0xFEE8`) | Notify | Quintic OTA result codes |

### Encryption

- **Algorithm**: AES-128 via native `libAES.so` (`keyExpansionDefault()`)
- **Mode**: ECB with fixed default key compiled into the native binary
- **Key (recovered)**: `34522a5b7a6e492c08090a9d8d2a23f8` — 16 bytes at `.so` file offset `0x3020` in the APK split's arm64 `libAES.so`; identical to the public iDeal LED family key. App-derived, not yet verified against hardware.
- **All** command/notify traffic and WRITE2/WRITE3 data is encrypted before write; responses decrypted on receive. OTA traffic on `0xFEE8` is **not** encrypted.

### Device Discovery

Identified by manufacturer-specific advertising data (not by name):

- AD type `0xFF`, payload starts with `{0x54, 0x52, 0x00, 0x27}` ("TR" + 0x0027)

### Commands

All commands are 16-byte fixed-length packets (plaintext, before AES encryption). Format: `[length, ASCII_CMD..., params..., zero_pad_to_16]`.

| Command | Bytes (plaintext) | Description |
|---------|-------------------|-------------|
| STYPE | `[5, 'S','T','Y','P','E']` | Query display dimensions (builder exists in the app but is never called — the device pushes STYPE unsolicited after connect) |
| LEDON | `[5, 'L','E','D','O','N']` | Turn display ON |
| LEDOFF | `[6, 'L','E','D','O','F','F']` | Turn display OFF |
| LEDFIRST | `[8, 'L','E','D','F','I','R','S','T']` | Address unit as first of a daisy chain |
| LEDSECOND | `[9, 'L','E','D','S','E','C','O','N','D']` | Address unit as second of a daisy chain |
| LIGHT n | `[6, 'L','I','G','H','T', n]` | Set brightness |
| LIGHTON | `[7, 'L','I','G','H','T','O','N']` | Torch/flashlight ON |
| LIGHTOFF | `[8, 'L','I','G','H','T','O','F','F']` | Torch/flashlight OFF |
| SPEED n | `[6, 'S','P','E','E','D', n]` | Set animation speed |
| MODE 1 | `[5, 'M','O','D','E', 1]` | Static display |
| MODE 2 hi lo | `[7, 'M','O','D','E', 2, hi, lo]` | Flash (ms, big-endian) |
| MODE 3 n | `[6, 'M','O','D','E', 3, n]` | Scroll left |
| MODE 4 n | `[6, 'M','O','D','E', 4, n]` | Scroll right |
| MODE 7 | `[5, 'M','O','D','E', 7]` | Rhythm/music mode (level frames go to WRITE3) |
| MODE 8 n | `[6, 'M','O','D','E', 8, n]` | Daisy-chained scroll right, with speed byte |
| MODE 9 n | `[6, 'M','O','D','E', 9, n]` | Daisy-chained scroll left, with speed byte |
| EVERT | `[5, 'E','V','E','R','T']` | Invert/flip display |
| ANIM n | `[5, 'A','N','I','M', n]` | Select animation frame |
| TIME h m s | `[7, 'T','I','M','E', h, m, s]` | Set device clock |
| SCHD on h m | `[7, 'S','C','H','D', on, h, m]` | Timer auto-off schedule |
| STSC | `[4, 'S','T','S','C']` | Read timer schedule (response prefix `SBHD`) |
| CALL s t | `[6, 'C','A','L','L', status, time]` | Phone call notification |
| SMVEW n | `[6, 'S','M','V','E','W', n]` | DIY sync draw: 1 = enter, 0 = exit, 2 = save-and-exit |
| STOPR | `[5, 'S','T','O','P','R']` | Stop music/rhythm mode |

The sibling Shining Glasses multi-frame `MANY <count> <profile>` … `MANCPOK` transaction does **not** exist in this app (no such command or dispatch code in the decompiled APK); animation upload here is a plain DATS/data/DATCP transfer. All command bytes above are verified directly against com.tirohk.magicdisplay 1.5.6 by static analysis of its protocol-agreement class.

### Data Transfer Protocol

1. **DATS** on WRITE1: `[8, 'D','A','T','S', len_hi, len_lo, 0, link_flag]`
2. Device responds **DATSOK** on notify
3. Send data chunks on WRITE2: `[payload_len, ...data]` — 16-byte blocks carrying up to 15 payload bytes each, **each block AES-128-ECB encrypted** with the same static key; 60 ms pacing for images, 50 ms for animations. No per-chunk acknowledgement; flow control is timing-only.
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
7. Device pushes `STYPE` unsolicited, identifying display resolution

### Vendor Cloud (not required)

The app — never the device — contacts `http://api.e-toys.cn/api/` for an OTA-version check (`app/lastOtaUpdate`), ads (`ad/getAdInfo`) and telemetry (`app/uploadLog`, `app/runningLog`). As of 2026-07-31 the server is alive but returns empty data for this app id; no OTA firmware is served. All control is local BLE, and four OTA images (`TR1805R03-9/-10`, `TR1806R06-2/-3`, ~39 KB each) are bundled in the APK assets, so the device remains fully usable — including firmware update — if the backend disappears.

## Tools Used

- [x] APK decompilation (jadx)
- [ ] HCI snoop capture (pending)
- [x] Native library (libAES.so) key extraction (arm64 `libAES.so`, offset `0x3020`)

## References

- [Google Play: Magic Display](https://play.google.com/store/apps/details?id=com.tirohk.magicdisplay)

## Contributors

- APK static analysis (jadx decompilation)
