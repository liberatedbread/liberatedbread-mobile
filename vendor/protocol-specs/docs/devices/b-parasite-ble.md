# b-parasite Soil Sensor

> **Status**: Spec Available (unverified) — active; open by design (BTHome v2)
> **Protocol**: BLE
> **Manufacturer**: rbaron (open-source project)
> **Manufacturer Status**: Active

## Overview

b-parasite is an open-source (nRF52) BLE soil-moisture sensor that also reports air temp/humidity, light and battery. Its default firmware broadcasts in BTHome v2 — decode per the BTHome v2 reference. Passive, no pairing, no cloud.

## Protocol Summary

Default: BTHome v2 in service data UUID 0xFCD2 (moisture 0x14, temperature 0x02, humidity 0x03, voltage 0x0C), keyed by MAC. A legacy custom advertisement is decoded by the ESPHome b_parasite component.

See `device-specs/devices/b-parasite-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/rbaron/b-parasite>
- <https://esphome.io/components/sensor/b_parasite.html>
