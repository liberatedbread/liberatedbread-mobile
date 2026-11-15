# Anki Overdrive / Anki Drive (BLE)

> **Status**: Shutdown — Anki closed 2019; Digital Dream Labs then collapsed
> **Protocol**: BLE
> **Manufacturer**: Anki (assets later Digital Dream Labs)
> **Manufacturer Status**: Shutdown

## Overview

BLE-controlled smart battle cars on a physical track. Doubly abandoned, and Anki itself published drive-sdk (Apache-2.0) — a clean rescue.

## Protocol Summary

BLE service BE15BEEF-...; read (telemetry) BE15BEE0, write (control) BE15BEE1. Vehicle messages (set speed, change lane) per drive-sdk's protocol.h. No pairing secret.

See `device-specs/devices/anki-overdrive-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/anki/drive-sdk>
- <https://github.com/anki/drive-sdk/blob/master/include/ankidrive/vehicle_gatt_profile.h>
