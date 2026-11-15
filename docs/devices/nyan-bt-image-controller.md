# Nyan BT Image Controller (NYAN GEAR)

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: NYAN GEAR / LOY SPACE / popled.cn
> **Manufacturer Status**: Abandoned

## Overview

BLE-only white-label reskin of the [LOY SPACE protocol](autobaba-led-backpack.md). Identical packet format, commands, and backend API. The NYAN GEAR app (com.nyan.gear v1.0.8) is BLE-only; the LOY SPACE app (com.yskd.loywf v1.2.19) adds Wi-Fi support. Both share the same DCloud uni-app framework (compiler v4.85).

See [AUTOBABA LED Backpack](autobaba-led-backpack.md) for the full protocol specification.

## Hardware

| Property | Value |
|----------|-------|
| Display | Full-color LED matrix (default 32x16, multiple sizes supported) |
| Chipset | Unknown |
| Radio | BLE |
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

### Key Differences from LOY SPACE (AUTOBABA)

| Feature | NYAN GEAR | LOY SPACE |
|---------|-----------|-----------|
| Default mode | BLE | Wi-Fi |
| Wi-Fi support | None | Full (UDP port 9090) |
| Video upload | Not included | KJ-FFmpeg plugin |
| Default resolution | 32x16 | 64x64 |

### Packet Format, Commands, and Image Upload

Identical to [AUTOBABA LED Backpack](autobaba-led-backpack.md). Same 0xAA55 header, JSON commands, BMP image encoding, and sliding window ACK protocol.

## Tools Used

- [x] APK decompilation (jadx)
- [ ] HCI snoop capture (pending)

## References

- [Google Play: NYAN GEAR](https://play.google.com/store/apps/details?id=com.nyan.gear)

## Contributors

- APK static analysis (jadx decompilation)
