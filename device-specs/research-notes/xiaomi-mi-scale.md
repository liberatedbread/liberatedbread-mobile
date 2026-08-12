# Research Notes: Xiaomi Mi Scale

## Source Repos
- oliexdev/openScale — primary RE, production Android app (Java/Kotlin)

## Key Findings

### BLE Services
- Weight Scale: `0000181d-0000-1000-8000-00805f9b34fb` (v1 primary, v2 alternate)
- Body Composition: `0000181b-0000-1000-8000-00805f9b34fb` (v2 primary)
- Device Info: `0000180a-0000-1000-8000-00805f9b34fb`
- Mi Vendor: `00001530-0000-3512-2118-0009af100700` (v2 only)

### Characteristics
- Weight Measurement: `00002a9d` (often absent on Mi — weight arrives via history char)
- Weight Scale Feature: `00002a9e`
- History: `00002a2f-0000-3512-2118-0009af100700` (custom, write+notify)
- Current Time: `00002a2b`
- Mi Config: `00001542-0000-3512-2118-0009af100700` (v2 only, unit setting)

### v1 vs v2 Detection
- v1 advertised names: "MI_SCALE", "MI_SCALE2"
- v2 advertised names: "MIBCS", "MIBFS"
- v2 has service 0x1530 (Mi vendor config)
- v2 includes impedance measurement for body composition

### Protocol - Weight Frame (10 bytes)
```
[ctrl_byte][weight_lo][weight_hi][year_lo][year_hi][month][day][hour][min][sec]
```
Control byte: Bit0=LBS, Bit4=Jin, Bit5=Stabilized, Bit7=WeightRemoved
Valid: Bit5=1 AND Bit7=0
Weight: /100 for lbs/jin, /200 for kg

### Protocol - v2 Live Frame (13 bytes)
10-byte format + 3 extra bytes. Control byte 1: Bit0=LBS, Bit1=hasImpedance.
Control byte 2: Bit5=Stabilized, Bit6=isCatty, Bit7=WeightRemoved.
Impedance: uint16 LE at bytes 9-10.

### Protocol - History Download
1. Enable notify on 0x2A2F
2. Write magic: `01 96 8A BD 62`
3. Write "only last": `01 FF FF <id_hi> <id_lo>`
4. Write trigger: `02`
5. Receive 10-byte records, ending with `03`
6. Ack stop: `03`
7. Ack final: `04 FF FF <id_hi> <id_lo>`

### Protocol - Time Sync
Write to 0x2A2B: `[year_lo, year_hi, month, day, hour, min, sec, 0x00, 0x00, 0x01]`

### Protocol - Unit Config (v2 only)
Write to 0x1542: `06 04 00 <unit>` where 0=kg, 1=jin, 2=lbs

## Confidence
- HIGH: all UUIDs, weight frame, history protocol, v2 impedance — from MiScaleHandler.kt in openScale
- HIGH: v1/v2 variant detection, body composition algorithms (Xiaomi and bodymiscale-science)
- HIGH: control byte bit layout (extensively tested across hundreds of users)
