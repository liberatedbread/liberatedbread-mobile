# Renogy BT-1 / BT-2 Solar Controllers (BLE)

> **Status**: Spec Available (unverified) — active
> **Protocol**: BLE
> **Manufacturer**: Renogy (Rover/Wanderer/Adventurer controllers; SRNE / Rich Solar rebadges)
> **Manufacturer Status**: Active

## Overview

Renogy's BT-1/BT-2 modules bridge a Renogy charge controller (Rover/Wanderer/Adventurer) over BLE — Modbus RTU tunneled through GATT, no cloud.

## Protocol Summary

Write Modbus requests to characteristic 0xFFD1, responses on 0xFFF1. Read register 0x0100 (34 words) for the main telemetry block (battery %, voltage, current, PV power, charging status). Name prefix `BT-TH-`.

See `device-specs/devices/renogy-bt-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/cyrils/renogy-bt>
