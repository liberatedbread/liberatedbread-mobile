# RuuviTag

> **Status**: Spec Available (unverified) — active; open published format
> **Protocol**: BLE
> **Manufacturer**: Ruuvi Innovations Ltd
> **Manufacturer Status**: Active

## Overview

The RuuviTag is an open BLE environmental sensor. Ruuvi publishes its advertisement formats and firmware — passive listen, no pairing, no cloud.

## Protocol Summary

Manufacturer data, company id 0x0499. Data Format 5 (RAWv2), 24 bytes MSB-first: temperature ×0.005 °C @1, humidity ×0.0025 % @3, pressure (1 Pa −50000 offset) @5, acceleration, battery mV, sequence. Legacy DF3 (14 bytes) too.

See `device-specs/devices/ruuvitag-ble.yaml` for the full machine-readable spec.

## References

- <https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2>
- <https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-3-rawv1>
