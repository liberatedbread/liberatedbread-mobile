# Inkbird IBS-TH1 / IBS-TH2 Thermometer-Hygrometer

> **Status**: Complete (parser-library-derived)
> **Protocol**: BLE (passive advertisements + optional GATT poll)
> **Manufacturer**: Inkbird
> **Manufacturer Status**: Active

## Overview

Cheap battery BLE temperature/humidity sensors (IBS-TH1, IBS-TH2, and the
IBS-P01B pool thermometer) that broadcast every reading in BLE
advertisements — no connection, pairing or account needed. Documented from
the Bluetooth-Devices/inkbird-ble parser library (which backs the Home
Assistant core `inkbird` integration) and its capture-pinned test suite,
not from an app teardown.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | IBS-TH1, IBS-TH2, IBS-P01B |
| Radio | BLE 4.x (legacy advertising) |
| Advertised name | `sps` (IBS-TH1), `tps` (IBS-TH2/P01B) |
| Advertised service | `0000fff0-0000-1000-8000-00805f9b34fb` |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` (passive scan) |
| Setup AP / advertised name | `sps` / `tps` |
| Passphrase protection | not_applicable |
| Confidence | high (production parser library + captured advertisements) |

**Factory reset**: none documented, and none needed — the device holds no
credentials or bindings. Removing the battery for 10+ seconds is the only
meaningful reset.

**Rebinding**: in place, trivially. The sensor is broadcast-only; any client
can listen, and switching controllers is just scanning from the new one.

## Protocol Summary

Advertisement quirk: **there is no company ID** — the temperature occupies
the company-ID position of the manufacturer-data AD structure, so BLE stacks
report the temperature itself as the "manufacturer id" and every new reading
looks like a new manufacturer-data entry. Match on name + service UUID +
9-byte length, never on a company id.

### Manufacturer data (9 bytes, on-air AD content)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | Temperature, s16 LE, /100 °C (`fc 07` → 0x07FC → 20.44 °C) |
| 2 | 2 | Humidity, u16 LE, /100 % (`c7 12` → 48.07 %) |
| 4 | 3 | Unidentified |
| 7 | 1 | Battery percent (`0x56` → 86) |
| 8 | 1 | Flags (0x06/0x08 observed), unknown |

Example frame `fc 07 c7 12 00 c8 3d 56 06` → 20.44 °C, 48.07 %, 86 %.
Decoded humidity above 100 % marks a corrupt packet — drop it whole.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000fff0-...-00805f9b34fb` | Inkbird Sensor Service | Shared with the iBBQ family — not sufficient for identification |
| `0000fff2-...-00805f9b34fb` | Sensor data (read) | Optional poll: temp s16 LE /100 @ bytes 0-1, humidity u16 LE /100 @ bytes 2-3; no battery byte |

Note the fff0 service is shared with the iBBQ BBQ thermometers
(spec `device-specs/devices/ibbq-meat-thermo.yaml`), and the
IBT/IBBQ-4BW line uses a completely different `0000ff00` ASCII-hex protocol
(spec `device-specs/devices/inkbird-bbq-thermometer.yaml`).
Discriminate by name + manufacturer-data length + service UUID.

## Tools Used

- [ ] Bluetooth-Devices/inkbird-ble parser + tests (no hardware capture done here)

## References

- [Bluetooth-Devices/inkbird-ble](https://github.com/Bluetooth-Devices/inkbird-ble)
- [Ernst79/bleparser inkbird.py](https://github.com/Ernst79/bleparser/blob/c42ae922e1abed2720c7fac993777e1bd59c0c93/package/bleparser/inkbird.py)
- [ble_monitor](https://github.com/custom-components/ble_monitor)
- [Home Assistant inkbird integration](https://www.home-assistant.io/integrations/inkbird)

## Contributors

- @kimi - spec from third-party parser sources
