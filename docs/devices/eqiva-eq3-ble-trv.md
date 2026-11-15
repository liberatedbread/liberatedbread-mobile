# eQ-3 Eqiva Bluetooth Radiator Thermostat

> **Status**: Spec Available (unverified) — active; huge EU install base
> **Protocol**: BLE
> **Manufacturer**: eQ-3 AG (Eqiva)
> **Manufacturer Status**: Active

## Overview

The Eqiva eQ-3 (CC-RT-BLE) Bluetooth radiator valve — a very common European smart TRV with no radio but BLE, so control is entirely local.

## Protocol Summary

Commands written to a vendor GATT characteristic, status on a notify char: `41 <°C×2>` set target, `40 00`/`40 40` auto/manual, `45 01` boost, `f0` factory reset. Firmware 1.20+ may need a one-time BLE pairing.

See `device-specs/devices/eqiva-eq3-ble-trv.yaml` for the full machine-readable spec.

## References

- <https://github.com/Heckie75/eQ-3-radiator-thermostat>
- <https://github.com/rytilahti/python-eq3bt>
