# Cat Printer MXW01

> **Status**: Protocol documented from three independent hardware-tested open implementations; not replayed against hardware here
> **Protocol**: BLE (GATT, no pairing)
> **Manufacturer**: Unbranded / various OEMs
> **Manufacturer Status**: Unsupported (no official third-party support; vendor app requires an account)

## Overview

The MXW01 is the 2024/2025 hardware revision of the cat-shaped mini
thermal printer. It **replaces** the protocol of the older GB01/MX05
family (see the `cat-printer` spec):
same BLE service UUIDs, but frames start with `0x22 0x21` instead of
`0x51 0x78`, the command IDs are new, and image data gets its own
characteristic. There is no cloud dependency anywhere in the print
path — the only reason to liberate it is to skip the account-requiring
vendor app.

## Hardware

| Property | Value |
|----------|-------|
| Model | MXW01 |
| Print method | Direct thermal, 384 px row (48 bytes/row at 1bpp) |
| Modes | 1bpp monochrome; 4bpp grayscale ("HD" in the vendor app) |
| Radio | BLE (service `0xAE30`; may appear as `0xAF30` on Apple platforms) |
| Power | Battery-powered; battery level queryable over BLE |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` — scan for name `MXW01` + service `0xAE30`, connect |
| Passphrase protection | not_applicable |
| Confidence | high (three hardware-tested clients agree) |

**Factory reset**: no credential state exists; a power cycle resets the
connection (low confidence — simply nothing to reset).

**Rebinding**: any central in range can connect; there is no bonding to
undo.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0xAE30` | MXW01 Printer Service | Sole service; carries the three characteristics below |
| `0xAE01` | Control | Write: all framed commands |
| `0xAE02` | Notify | Responses + unsolicited print-complete |
| `0xAE03` | Data | Write-without-response: raw image rows only |

### Frame format

`[0x22 0x21] [cmd] [0x00] [len u16 LE] [payload] [crc8] [0xFF]`

CRC-8 (poly `0x07`, init `0x00`, no reflection) over the payload only —
the same CRC as the legacy family. Responses may drop the CRC/footer;
parse by declared length.

### Commands

| ID | Name | Payload |
|----|------|---------|
| `A1` | get_status | `00`; reply layout below |
| `A2` | set_intensity | 1 byte `00`–`FF` (`5D` default) |
| `A3` / `A4` | eject / retract paper | u16 LE line count |
| `A9` | print_request | `[lines u16 LE] 30 [mode]` — mode 0=1bpp, 2=4bpp |
| `AA` | print_complete | notification, physical print done |
| `AB` | get_battery_level | `00`; reply byte 0 = level |
| `AC` | cancel_print | `00` |
| `AD` | print_data_flush | `00`; send after last `AE03` chunk |
| `B0` / `B1` | get_print_type / get_version | `00`; version reply carries a UTF-8 string |
| `A7`, `B2`, `B3` | unknown | observed in the vendor app; purpose unclear |

**Status reply (`A1`) payload**: `[0]` state (0 standby, 1 printing,
2 feeding, 3 ejecting), `[3]` battery, `[4]` temperature, `[6]` overall
flag (0 = OK), `[7]` error bitmask (0x01 no paper, 0x04 overheated,
0x08 low battery). (jeremy46231's PROTOCOL.md shows these at offsets
6–13 because its "payload" indices include the 6-byte frame header.)

### Print sequence

1. Subscribe to `AE02`; optional `A2` set intensity.
2. `A1` status → wait for reply → abort unless flag byte is 0.
3. `A9` print request (line count, mode) → wait for accept (`payload[0] == 0`).
4. Stream rows on `AE03`: 1bpp rows are 48 bytes, **LSB = leftmost
   pixel, no bit reversal** (unlike the legacy family); 4bpp packs two
   pixels per byte, high nibble first. Pace writes (~15 ms per row or
   ~100 ms per MTU chunk — there is no flow control). Pad with `0x00`
   to at least 4320 bytes (90 rows) or the job won't print.
5. `AD` flush → wait for the `AA` print-complete notification
   (~15 lines/sec plus margin).
6. Optional `A3` eject to advance past the tear edge.

Images come out bottom-first; rotate 180° client-side for right-side-up
output.

## Tools Used

- [x] Published protocol write-up (jeremy46231's PROTOCOL.md)
- [x] Three independent open implementations read in source
- [ ] Own hardware capture (none — contributions welcome)

## References

- [MaikelChan/CatPrinterBLE](https://github.com/MaikelChan/CatPrinterBLE) — first full client (C#), hardware-tested
- [jeremy46231/MXW01-catprinter](https://github.com/jeremy46231/MXW01-catprinter) — Python client + PROTOCOL.md, hardware-tested
- [eerimoq/moblin CatPrinter integration](https://github.com/eerimoq/moblin/tree/main/Moblin/Integrations/CatPrinter) — earliest MXW01 support (Swift)
- [clementvp/mxw01-thermal-printer](https://github.com/clementvp/mxw01-thermal-printer) — TypeScript/Web Bluetooth library
- `cat-printer` spec (legacy family) — older family, incompatible protocol

## Contributors

- Liberated Bread research agent — consolidation from public prior art

Machine-readable spec: `device-specs/devices/cat-printer-mxw01.yaml`
