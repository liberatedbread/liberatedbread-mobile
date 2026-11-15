# Mopeka Pro Check Tank Sensor

> **Status**: Spec Available (unverified) — active; community-decoded broadcast
> **Protocol**: BLE
> **Manufacturer**: Mopeka Products LLC
> **Manufacturer Status**: Active

## Overview

Mopeka Pro Check ultrasonic tank sensors report a tank's fill level from ultrasonic time-of-flight to the liquid surface. The BLE broadcast is decoded passively (as ESPHome does) — no cloud, no pairing.

## Protocol Summary

Passive broadcast, keyed by MAC (press the sync button to surface it). Reports tank level %, raw distance (mm), sensor temperature, battery %, and a quality enum (HIGH/MEDIUM/LOW/ZERO). Level derives from distance via a tank-shape calibration.

See `device-specs/devices/mopeka-pro-check-ble.yaml` for the full machine-readable spec.

## References

- <https://esphome.io/components/sensor/mopeka_pro_check.html>
