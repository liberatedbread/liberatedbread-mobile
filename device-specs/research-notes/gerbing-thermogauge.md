# Gerbing / GYDE ThermoGauge — Research Note
# Generated: 2026-07-28
# Source: APK static analysis (Thermogauge.Core.dll IL disassembly)

## UUID Summary

### Services
| Service | UUID |
|---------|------|
| Device Information (SIG) | 0000180a-0000-1000-8000-00805f9b34fb |
| Temperature | ab06bd90-cc16-11e4-8830-0800200c9a66 |
| Battery (SIG) | 0000180f-0000-1000-8000-00805f9b34fb |
| Heat Control | 729f0608-496a-47fe-a124-3a62aaa3fbc0 |

### Characteristics
| Characteristic | UUID | Properties |
|---------------|------|------------|
| Device Type | 0313fb4e-198b-4f64-a883-52b218c10ccc | read |
| Temp Channel 1 | ab06bd91-cc16-11e4-8830-0800200c9a66 | read, notify |
| Temp Channel 2 | ab06bd92-cc16-11e4-8830-0800200c9a66 | read, notify |
| Battery Level (SIG) | 00002a19-0000-1000-8000-00805f9b34fb | read, notify |
| Heat Channel 1 | 90759319-1668-44da-9ef3-492d593bd1e5 | read, write, notify |
| Heat Channel 2 | 80c37f00-cc16-11e4-8830-0800200c9a66 | read, write, notify |

## Data Formats

### Heat Write (1 byte)
- `(byte)float_value`, 0-100 percent
- No clamps applied in app — firmware behavior above 100 unknown

### Temperature Read (1 byte, unsigned)
- Display: `ceil((raw / 2 + 85) / 5) * 5`
- Inferred °F: raw=0→85, raw=142≈156, raw=255≈215
- TempControl mode: 60 <= raw < 142 (~115-155°F)

### Battery Level (1 byte)
- Standard SIG Battery Level (0x2A19), 0-100%

### Device Type (1 byte)
- High nibble: heat output channels (1-2)
- Low nibble: temperature sensor inputs (1-2)
- Custom characteristic under standard DIS (0x180A)

## Discovery
- Scan filter: name `Contains("Gerbing") || Contains("Gyde")`
- NOT a prefix match — substring anywhere in advertised name
- Voltage detection: name `Contains("12V")` → 12V mode, else 7.4V

## Procedure
1. Scan for BLE devices with "Gerbing" or "Gyde" in name
2. Connect → discover services
3. Read DeviceType (0313fb4e-…) → determine channel count
4. Read Temp chars, Battery Level via notifications/poll
5. Write 1-byte heat levels to Heat chars

## Confidence
HIGH — all UUIDs from ldstr→stfld IL pairs, all formats from IL bytecode.
Remaining: confirm °F vs °C, verify notification support, test heat >100.
