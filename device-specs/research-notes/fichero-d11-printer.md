# Research Notes: Fichero / AiYin D11 Thermal Label Printer

## Source Repos
- 0xMH/fichero-printer — primary RE, Python CLI and Web GUI

## Key Findings

### BLE Details
- 4 BLE UART services (all functionally equivalent):
  - `000018f0-0000-1000-8000-00805f9b34fb` (primary — write: 0x2AF1, notify: 0x2AF0)
  - `0000ff00-0000-1000-8000-00805f9b34fb` (write: 0xFF02, notify: 0xFF01/0xFF03)
  - `e7810a71-73ae-499d-8c15-faa9aef0c3f2` (same char for write+notify)
  - `49535343-fe7d-4ae5-8fa9-9fafd205e455` (write: ...9bb3, notify: ...9616)
- Advertised names: "FICHERO_XXXX", "D11s_"
- Also supports Classic Bluetooth SPP

### Hardware
- Printhead: 96px (12 bytes/row), 203 DPI
- Battery: 18500 Li-Ion, 1200mAh, USB-C charging
- SDK: LuckPrinter SDK (com.luckprinter.sdk_new) — supports 159+ models

### Protocol (AiYin device class)
**Info commands:**
- Get model: `10 FF 20 F0` → ASCII string
- Get firmware: `10 FF 20 F1` → ASCII string
- Get serial: `10 FF 20 F2` → ASCII string
- Get battery: `10 FF 50 F1` → 2 bytes [status, percent]
- Get status: `10 FF 40` → 1 byte bitmask

**Status byte bitmask:** Bit0=printing, Bit1=cover open, Bit2=no paper, Bit3=low battery, Bit4=overheated(alt), Bit5=charging, Bit6=overheated

**Config commands:**
- Set density: `10 FF 10 00 nn` (0=light, 1=medium, 2=thick)
- Set paper type: `10 FF 84 nn` (0=gap, 1=black mark, 2=continuous)
- Set shutdown time: `10 FF 12 HH LL` (big-endian minutes)
- Factory reset: `10 FF 04`

**Print sequence:**
1. Set density: `10 FF 10 00 nn`
2. Set paper type: `10 FF 84 00`
3. Wake up: 12 null bytes
4. Enable printer: `10 FF FE 01` (AiYin-specific)
5. Raster header: `1D 76 30 00 xL xH yL yH` + pixel data
6. Form feed: `1D 0C`
7. Stop print: `10 FF FE 45`

Raster: 1-bit BMP, MSB first, 12 bytes/row.
Header format: `1D 76 30 mode xL xH yL yH`
- mode: 0=normal, 1=double-width, 2=double-height, 3=both
- D11s width: 0C 00 (12 bytes = 96px)

### Device-class specific commands
- AiYin (D11s, D12): enable=`10 FF FE 01`, stop=`10 FF FE 45`
- Lujiang (L13, etc): enable=`10 FF F1 03`, stop=`10 FF F1 45`
Using wrong pair = silent failure.

## Confidence
- HIGH: all service/characteristic UUIDs, info/config commands, print sequence, raster format
- MEDIUM: firmware update protocol
- LOW: speed setting, width setting (not supported on D11s)
