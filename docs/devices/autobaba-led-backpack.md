# AUTOBABA LED Backpack

> **Status**: Complete
> **Protocol**: BLE + Wi-Fi
> **Manufacturer**: LOY SPACE / popled.cn
> **Manufacturer Status**: Abandoned

## Overview

Programmable full-color LED backpack screen. Uses the **LOY SPACE / popled.cn protocol** — identical to [NYAN BT Image Controller](nyan-bt-image-controller.md). The LOY SPACE app (com.yskd.loywf) is the full-featured variant with both BLE and Wi-Fi support. The NYAN GEAR app (com.nyan.gear) is a BLE-only white-label reskin of the same platform.

## Hardware

| Property | Value |
|----------|-------|
| Display | Full-color LED matrix (multiple sizes: 16x16 to 192x40) |
| Chipset | Unknown |
| Radio | BLE + Wi-Fi |
| FCC ID | Unknown |

## Protocol Summary

### BLE Services

| UUID | Name |
|------|------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | LOY SPACE BLE Service |

### Characteristics

| UUID | Name | Properties | Purpose |
|------|------|------------|---------|
| `0000fff1-0000-1000-8000-00805f9b34fb` | Notify | Read, Notify | Device acknowledgements |
| `0000fff2-0000-1000-8000-00805f9b34fb` | Write | Write | Commands and image data |

### BLE Parameters

| Parameter | Value |
|-----------|-------|
| Write max bytes | 248 |
| Inter-write delay | 10 ms |
| BLE buffer size | 180 bytes |

### Device Discovery

- **BLE name prefix**: `"YS"` or `"TL"`
- **Wi-Fi SSID**: Contains `"YS"` (AP mode, default password: `12345678`)

### Wi-Fi Protocol

1. Connect to device AP (SSID starting with "YS")
2. Bind UDP port **9090**
3. Broadcast discovery to `192.168.4.255:9090`: `aa 55 ff ff 08 00 01 00 c1 03 0a 00 d4 03`
4. Device responds from `192.168.4.1` (AP gateway)
5. Same binary packet protocol used over Wi-Fi as over BLE

### Packet Format

All packets (BLE and Wi-Fi) use the same binary format:

| Offset | Size | Value | Description |
|--------|------|-------|-------------|
| 0 | 2 | `0xAA 0x55` | Magic header |
| 2 | 2 | `0xFF 0xFF` | Address (broadcast/default) |
| 4 | 2 | varies | Payload length (little-endian) |
| 6 | 2 | varies | Sequence number |
| 8 | 1 | varies | Command flags (0xC1 for programs) |
| 9 | 1 | varies | Command type |
| 10+ | varies | varies | Payload |

### Commands (JSON-based)

Commands are JSON objects serialized to binary TLV packets:

| Command | JSON | Description |
|---------|------|-------------|
| Power toggle | `{power:{type:0}}` | Toggle screen on/off |
| Set brightness | `{light:{type:0, value_fix:N}}` | Brightness 0-15 |
| Get device info | `{get:"dev_info"}` | Query device info |
| Get power state | `{get:"power"}` | Query power state |
| Delete all | `{delete:{del_all:1}}` | Delete all programs |
| Play program | `{pgm_play:{model:0, index:N}}` | Play by index |
| Loop programs | `{pgm_play:{model:2, ids_pro:[...]}}` | Loop specific programs |
| Set rotation | `{rotate:N}` | Screen rotation |
| Set password | `{pwd:{type:1, val:"123456"}}` | Set device password |
| Real-time draw | `{rt_draw:{color:"", type:16, data:[...]}}` | Pixel drawing |
| Format device | `{delete:{format:1}}` | Factory reset |

### Image Upload

1. Render content to Canvas at device resolution
2. Convert RGBA to **24-bit uncompressed BMP** (`rgbtobmp`)
3. Wrap in `pkts_program` structure with metadata (width, height, type)
4. Serialize to TLV packets
5. Send via BLE write (248-byte chunks) or UDP

### Supported Resolutions

| Width | Height | Shape |
|-------|--------|-------|
| 16 | 16 | Rectangle |
| 32 | 16 | Rectangle (default for NYAN GEAR) |
| 32 | 32 | Rectangle or Round |
| 48 | 28 | Rectangle |
| 64 | 20 | Rectangle |
| 64 | 64 | Rectangle or Round |
| 96 | 128 | Rectangle |
| 160 | 32 | Wide banner |
| 192 | 40 | Extra-wide |

### Sliding Window ACK

| Parameter | Value |
|-----------|-------|
| Window size | 3 (default), 5, or 10 |
| BLE send timeout | 5000 ms |
| Wi-Fi send timeout | 10000 ms |
| BLE streaming interval | 20 ms |
| Max TLV packet | 997 bytes (128 for firmware < V2.8.7#V15) |

### Backend API

| Endpoint | URL |
|----------|-----|
| CDN / API | `https://store-cdn.popled.cn/` |
| Form CDN | `https://wxbtapp-cdn.popled.cn/` |
| Font CDN | `https://store-cdn.popled.cn/font_en/` |

Auth: `token = MD5(MD5(app_key) + timestamp)`. The `app_key` is a popled.cn / LOY
SPACE backend credential and is intentionally **`<redacted>`** here per the project
clean-room rules (no vendor keys/credentials in the repo).

## Tools Used

- [x] APK decompilation (jadx)
- [ ] HCI snoop / Wi-Fi capture (pending)

## References

- [Google Play: LOY SPACE](https://play.google.com/store/apps/details?id=com.yskd.loywf)

## Contributors

- APK static analysis (jadx decompilation)
