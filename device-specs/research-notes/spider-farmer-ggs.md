# Research Notes: Spider Farmer GGS Grow Light Controller

## Source Repos
- cr0ssn0tice/Spider-Farmer-GGS-Controller-MQTT — ESP32 MQTT bridge + Python tools

## Key Findings

### BLE Details
- Service UUID: `0000ff00-0000-1000-8000-00805f9b34fb`
- Notify characteristic: `0000ff01-0000-1000-8000-00805f9b34fb`
- Write characteristic: `0000ff02-0000-1000-8000-00805f9b34fb`
- Advertised name: "SF-GGS-CB" (exact match)
- No pairing or bonding required

### JSON Telemetry (notify on 0xFF01)
Device continuously streams JSON telemetry. Fragmented across multiple
BLE notification packets — must be buffered and accumulated.

```json
{
  "sensor": {"temp": 25.4, "humi": 55.2, "vpd": 1.2},
  "fan": {"level": 3, "on": 1},
  "blower": {"level": 0},
  "light": {"level": 100, "on": 1}
}
```

Fields:
- sensor.temp: temperature (°C)
- sensor.humi: relative humidity (%)
- sensor.vpd: vapor pressure deficit
- fan.level: fan speed (0-N)
- fan.on: fan state (0/1)
- blower.level: blower speed
- light.level: dimming level (0-100)
- light.on: light power (0/1)

### Commands (write JSON to 0xFF02)
- Get device status: `{"method":"getDevSta"}`
  (response arrives as notification on 0xFF01)
- Set light: `{"method":"setLight","data":{"on":1,"level":50}}`
  - on: 0=off, 1=on
  - level: 0-100 (dimming)
- Uses GATT write request (with response) for reliability

### ESP32 BLE Implementation Notes
- MTU set to 517 after connection
- Notifications must be manually enabled via CCCD (0x2902 descriptor)
  - Write `{0x01, 0x00}` to CCCD
- JSON parsing: accumulate until "fan\"" and "}}" are both present
- Buffer size: 2500 bytes (reset if exceeded)
- Only ASCII printable chars (32-126) are collected

### Hardware Context
- Price: $30-50
- Marketed as requiring cloud; actually fully local BLE
- Controls Spider Farmer LED grow lights
- Moderate power draw — no critical safety risk

## Confidence
- HIGH: service/characteristic UUIDs, JSON telemetry format, getDevSta + setLight
- HIGH: BLE connection details (MTU, CCCD, JSON accumulation)
- MEDIUM: additional commands (fan, blower, scheduling)
