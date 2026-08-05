# Ember Mug

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: Ember Technologies
> **Manufacturer Status**: Server-dependent (telemetry to collector.embertech.com; BLE control works locally)

## Overview

Temperature-controlled drinkware family including Ember Mug 2 (10/14 oz), Travel Mug 2/2+, Cup (6 oz), and Tumbler (16 oz). Reverse engineered via APK decompilation by the community. Full BLE control works without the cloud.

## Hardware

| Property | Value |
|----------|-------|
| Models | Mug 2 (CM19/CM21M), Travel Mug 2 (TM19), Cup (CM21S), Tumbler (CM21XL) |
| Chipset | Unknown (BLE SIG company ID: 0x03C1) |
| Radio | BLE |
| FCC ID | Not documented |

## Protocol Summary

### BLE Services

All characteristics use UUID pattern `fc54XXXX-236c-4c94-8fa9-944a3e5353fa`.

| UUID (short) | Name | Properties | Description |
|-------------|------|------------|-------------|
| `0x3622` | Mug Service | - | Primary service (Mug/Cup/Tumbler) |
| `0x3621` | Travel Mug Service | - | Primary service (Travel Mug) |
| `0x0001` | Mug Name | R/W | UTF-8, up to 14 bytes |
| `0x0002` | Current Temperature | R | uint16 LE, value * 0.01 = degrees C |
| `0x0003` | Target Temperature | R/W | uint16 LE, value * 0.01 = degrees C; 0x0000 = heater off |
| `0x0004` | Temperature Unit | R/W | 0x00 = Celsius, 0x01 = Fahrenheit |
| `0x0005` | Liquid Level | R | 0 = empty, 30 = not empty |
| `0x0006` | Date Time Zone | W | 4-byte Unix timestamp LE + 1-byte TZ offset |
| `0x0007` | Battery | R | byte 0: percent (5-100), byte 1: on charger (0/1) |
| `0x0008` | Liquid State | R | 0=standby, 1=empty, 2=filling, 4=cooling, 5=heating, 6=stable |
| `0x000C` | Firmware | R | 3x uint16 LE: firmware, hardware, bootloader version |
| `0x0012` | Push Event | R/N | Event ID (1-9) triggers re-read of related characteristic |
| `0x0014` | LED Color | R/W | 4 bytes: R, G, B, brightness (0-255 each) |

### Push Events

| ID | Event | Action |
|----|-------|--------|
| 1 | Battery Changed | Re-read battery |
| 2 | Charger Connected | Update charging state |
| 3 | Charger Disconnected | Update charging state |
| 4 | Target Temp Changed | Re-read target temp |
| 5 | Drink Temp Changed | Re-read current temp |
| 7 | Liquid Level Changed | Re-read liquid level |
| 8 | Liquid State Changed | Re-read liquid state |

### Discovery

- Advertised name starts with `"Ember"` (e.g., "Ember Ceramic Mug")
- BLE SIG company ID: `0x03C1`
- Pairing: standard BLE "Just Works" (non-fatal if it fails)

## Tools Used

- [x] APK decompilation (jadx)
- [x] Community open-source implementations

## References

- [orlopau/ember-mug](https://github.com/orlopau/ember-mug) -- protocol documentation
- [sopelj/python-ember-mug](https://github.com/sopelj/python-ember-mug) -- Python library
- [sopelj/hass-ember-mug-component](https://github.com/sopelj/hass-ember-mug-component) -- Home Assistant integration

## Contributors

- @orlopau -- original reverse engineering
- @sopelj -- Python library and HA integration
