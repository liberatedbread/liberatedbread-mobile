# Research Notes: iBBQ / Inkbird BLE Meat Thermometer

## Source Repos
- gleeds/cloudbbq — Node.js BLE client
- gist.github.com/uucidl — iBBQ protocol documentation

## Key Findings

### BLE Details
- Service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- Characteristics:
  - 0xFFF1 SettingsResult (notify) — responses to config writes
  - 0xFFF2 AccountAndVerify (write) — credential authentication
  - 0xFFF3 HistoryData (notify) — historical temperatures
  - 0xFFF4 RealtimeData (notify) — live temperature stream
  - 0xFFF5 SettingsData (write) — configuration commands
- CCCD descriptor: 0x2902 (standard)
- Advertised name: "iBBQ"

### Authentication
Fixed 15-byte credential (REQUIRED before any other command):
```
[0x21, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0xB8, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00]
```
Written to 0xFFF2. This is a FIXED magic sequence, not per-device auth.
Without it, all subsequent commands are ignored.

### Protocol
1. Connect BLE
2. Write credential to 0xFFF2
3. Enable notifications (CCCD) on 0xFFF4 + 0xFFF1
4. Enable realtime: `[0x0B, 0x01, 0x00, 0x00, 0x00, 0x00]` to 0xFFF5
5. Receive temperature data as notifications on 0xFFF4

### Temperature Encoding
- uint16 LE per probe in 0.1°C increments
- Divide by 10 to get °C
- num_probes = data_length / 2
- Multi-probe devices (2-6 probes) return multiple uint16 values

### Settings Commands (all 6-byte to 0xFFF5)
- Celsius: `[0x02, 0x00, 0x00, 0x00, 0x00, 0x00]`
- Fahrenheit: `[0x02, 0x01, 0x00, 0x00, 0x00, 0x00]`
- Silence alarm: `[0x04, 0xFF, 0x00, 0x00, 0x00, 0x00]`
- Battery request: `[0x08, 0x24, 0x00, 0x00, 0x00, 0x00]`
- Set target temp: `[0x01, probe#, low_lo, low_hi, high_lo, high_hi]`
  (temperatures as signed int16 × 10)

## Confidence
- HIGH: all UUIDs, credential packet, enable realtime, temperature encoding
- HIGH: settings commands (from uucidl gist and cloudbbq implementation)
- MEDIUM: history data format
