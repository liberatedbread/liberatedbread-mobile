# Research Notes: NIIMBOT D110 / B21 Thermal Label Printer

## Source Repos
- MultiMote/niimblue — Web Bluetooth client (Svelte/TypeScript), deployed at niim.blue
- MultiMote/niimbluelib — protocol library (npm package @mmote/niimbluelib)
- NIIMBOT Community Wiki — https://printers.niim.blue/

## Key Findings

### Protocol Overview
Packet-based binary protocol over BLE GATT. Packet format:
```
[0x03?] 0x55 0x55 <cmd> <data_len> <data...> <xor_checksum> 0xAA 0xAA
```
- 0x03 prefix: used only on Connect packet (0xC1)
- Checksum: XOR of command through last data byte (cmd ^ data_len ^ data[0] ^ ...)
- Simple request: cmd 0x01 0x01 → checksum = cmd (cmd ^ 0x01 ^ 0x01 = cmd)

### CRC32 Variant (Firmware)
Firmware packets use CRC32 checksum instead of XOR, and add an Index byte:
```
0x55 0x55 <cmd> <index> <data_len> <data...> <crc32> 0xAA 0xAA
```

### Print Sequence
1. **Connect** (0xC1) — handshake with 0x03 prefix
2. **PrintStart** (0x01) — announce total pages; D110 uses 1-byte variant
3. **SetPageSize** (0x13) — row count, column count, copies; D110 uses 2-byte
4. **SetDensity** (0x21) — print density
5. **SetLabelType** (0x23) — label type
6. **PageStart** (0x03) — begin page
7. **PrintBitmapRow** (0x85) / **PrintBitmapRowIndexed** (0x83) / **PrintEmptyRow** (0x84)
8. **PageEnd** (0xE3)
9. Repeat 6-8 for copies
10. **PrintEnd** (0xF3)

### Packet Command IDs
Major commands: 0x01 PrintStart, 0x03 PageStart, 0x13 SetPageSize,
0x15 PrintQuantity, 0x21 SetDensity, 0x23 SetLabelType, 0x28 PrinterReset,
0x40 PrinterInfo, 0x83 PrintBitmapRowIndexed, 0x84 PrintEmptyRow,
0x85 PrintBitmapRow, 0xC1 Connect, 0xDC Heartbeat, 0xE3 PageEnd, 0xF3 PrintEnd

### D110-Specific Format
- PrintStart: 1 byte `55 55 01 01 01 <cs> aa aa`
- SetPageSize: 2 bytes `55 55 13 02 <row_lo> <row_hi> <cs> aa aa`
  (column count = 384px, implicit)
- Printhead: 384px wide (48 bytes/row for 1-bit)

### Bitmap Row Encoding
- **PrintBitmapRow** (0x85): full row with black pixel count segment
- **PrintBitmapRowIndexed** (0x83): for rows with < 7 black pixels, uses uint16 pixel indexes
- **PrintEmptyRow** (0x84): fill row with white pixels, includes repeat count

### Heartbeat Responses
- Advanced 1 (0xDD): lid closed, charge level, paper inserted, RFID status
- Advanced 2 (0xD9): adds ribbon state, WiFi RSSI, voltage, lighting error
- Some models invert lid_closed bit (1=closed for 512/514/2304/etc. models)

### Service Discovery
Service UUID varies by model. The niimbluelib discovers service and characteristics
dynamically. The protocol is consistent across all NIIMBOT models; only the
GATT UUIDs and PrintStart/SetPageSize variant lengths differ.

## Confidence
- HIGH: packet format, checksum, command IDs — from production niimbluelib
- HIGH: D110-specific variant lengths (1-byte PrintStart, 2-byte SetPageSize)
- HIGH: bitmap row encoding (PrintBitmapRow, PrintBitmapRowIndexed, PrintEmptyRow)
- HIGH: heartbeat format and lid/paper/charge status bits
- MEDIUM: RFID functionality
- LOW: firmware upgrade protocol (CRC32 variant, not as well tested)
