# Qingping / ClearGrass Sensors (stock BLE broadcasts)

> **Status**: Spec Available (source-derived; untested on hardware here)
> **Protocol**: BLE service data `0xFDCD`, receive-only
> **Manufacturer**: Qingping / ClearGrass
> **Manufacturer Status**: Active

## Overview

Many Qingping and ClearGrass sensors broadcast current readings in stock BLE
advertisements. A client can receive them without connecting, pairing, an
account, a hub or the vendor cloud. The maintained `qingping-ble` parser and its
anonymized fixtures provide the protocol evidence; this project did not scan or
configure a physical sensor.

This page covers **stock `0xFDCD` service data only**. It does not cover PVVX
custom firmware, MiBeacon, BTHome, LoRaWAN products, or a GATT history and
configuration connection.

!!! warning "Unauthenticated broadcasts"
    The documented format has no sender authentication or replay protection.
    Validate packet lengths, retain unknown values as unavailable, and do not
    use one reading as the sole input to a medical alarm, safety interlock or
    high-confidence occupancy decision.

## Supported model identifiers

The second byte of the service-data value selects the model. Unknown IDs must
remain unknown rather than being assigned to a look-alike product.

| Type byte | Model |
|---|---|
| `0x01`, `0x07` | CGG1 |
| `0x04` | CGH1 Door/Window Sensor |
| `0x09` | CGP1W |
| `0x0c` | CGD1 Alarm Clock |
| `0x0e`, `0x24` | CGDN1 Air Monitor Lite |
| `0x0f` | CGM1 Lee Guitars Thermo-Hygrometer |
| `0x10` | CGDK2 Temp & RH Monitor Lite |
| `0x12` | CGPR1 Motion & Light |
| `0x15` | CGF1W Temp RH Pro E |
| `0x16` | CGG1 Temp RH M |
| `0x18` | CGP23W Temp & RH Monitor Pro |
| `0x1e` | CGC1 BT Clock Lite |
| `0x26` | CGP23W Temp RH Baro Pro S |
| `0x33`, `0x5d` | CGP22C CO2 Temp RH |
| `0x4f` | CGG3 Temp RH M |
| `0x52`, `0x62` | CGR1PC Indoor Environment Monitor |

The parser recognizes more models than Home Assistant's published support
list. Parser support is not physical verification: CGDK2, CGR1PC and CGP23W
Pro S still need captures on actual hardware.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No, for passive current readings |
| Method | `ble_direct`: scan service data, without connecting |
| Passphrase protection | not_applicable |
| Confidence | medium (maintained parser and fixtures; not replayed here) |

The historical Qingping Air app, current Qingping apps, optional Bluetooth
gateway, display settings and history synchronization are separate surfaces.
None is needed for this receive-only protocol.

**Factory reset**: no family-wide procedure is established. The archived CGG1
guide says its reset erases locally recorded data and releases app pairing.
That is a destructive model-specific owner operation, not something a passive
client needs or should trigger. Do not generalize it to the other models.

**Rebinding**: there is no passive-client bond or network membership to move.
Resume scanning. Recovering an app/history pairing is outside this document.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` for advertisement reception |
| Bonding | `none` |
| Confidence | medium |

The frames themselves contain no pairing proof or sender authentication. A
separate GATT configuration or history surface may have different security;
it is not covered here.

## Protocol Summary

Read service data associated with full UUID
`0000fdcd-0000-1000-8000-00805f9b34fb`. The offsets below begin at the
service-data **value**, after the UUID.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | Header/flags; bit 6 (`0x40`) marks an event packet |
| 1 | 1 | Device type from the model table |
| 2 | 6 | Address-like bytes; not used by the parser to prove identity or select a model |
| 8 | 1 | First TLV type |
| 9 | 1 | First TLV payload length |
| 10 | `length` | First TLV payload; further type-length-value records follow |

Require the complete header and each complete TLV before decoding. Skip an
unknown or truncated TLV without inventing values or discarding valid earlier
TLVs. All multibyte integers are little-endian.

### TLV map

| TLV | Length | Decode |
|---:|---:|---|
| `0x01` | 4 | Signed int16 temperature × 0.1 °C, then uint16 relative humidity × 0.1 % |
| `0x02` | 1 | Battery percent; `0xff` means externally powered and is displayed as 100, not measured battery capacity |
| `0x04` | 1 | Door/open true for 0 and 2; left-open/problem true only for 2 |
| `0x07` | 2 | Unsigned pressure × 0.1 mbar |
| `0x08` | 4 | Motion byte, low uint16 illuminance, high uint8 illuminance; on event packets update motion only |
| `0x09` | 4 | Unsigned uint32 illuminance in lux |
| `0x11` | 1 | Ambient-light boolean |
| `0x12` | 4 | PM2.5 and PM10, each uint16 in µg/m³ |
| `0x13` | 2 | CO₂, uint16 ppm |
| `0x15` | 2 | VOC index, uint16, unitless; exact range unresolved |
| `0x18` | 2 | Static hardware capability bitmap, **not CO₂** and not a sensor output |
| `0x19` | 1 | Sound pressure in dB |
| `0x0f` | 1 | Packet ID, metadata rather than a measurement |

For non-event TLV `0x08`, calculate illuminance as:

```text
uint16_le(payload[1:3]) + (payload[3] << 16)
```

On an event packet, ignore those three light bytes and retain the previous
illuminance. For every other omitted measurement, also retain the previous
value rather than replacing it with zero.

### Worked example

```text
08 10 00 00 00 00 00 00   01 04 1c 01 af 02   02 01 64
```

The address-like bytes are zero placeholders. Model `0x10` is CGDK2. TLV
`0x01` carries `0x011c` = 28.4 °C and `0x02af` = 68.7 % RH; TLV `0x02` reports
100 % battery.

`scripts/test_qingping_stock_ble_spec.py` independently walks the documented
envelope and TLVs. It also checks signed temperature, 24-bit illuminance,
truncation, the event-packet rule, and that capability TLV `0x18` never becomes
CO₂.

## Out of scope and remaining questions

History, alarms, names, display content, settings and firmware updates need a
separate documented interface. The remaining header bits, model-specific event
variants and VOC range are unresolved. Physical captures are still needed for
the newer parser mappings.

See `device-specs/devices/qingping-stock-ble.yaml` for the complete
machine-readable model and TLV maps.

## References

- [Bluetooth-Devices/qingping-ble (MIT)](https://github.com/Bluetooth-Devices/qingping-ble), pinned at `27d07f8d93648400024f1f1205c8f3fbd8982d72`
- [Home Assistant Qingping integration](https://www.home-assistant.io/integrations/qingping/)
- [Qingping CGG1 user guide (archived PDF)](https://web.archive.org/web/20230101000000/https://mi-house.ru/asserts/instructions/2321/1/CGG1.pdf)
- [Qingping Bluetooth gateway](https://qingping.co/bluetooth-gateway)
