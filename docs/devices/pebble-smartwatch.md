# Pebble Smartwatch

> **Status**: Abandoned — Pebble closed 2016; firmware open-sourced 2025, revived by Rebble
> **Protocol**: BLE
> **Manufacturer**: Pebble Technology (defunct 2016; revived via Rebble + Core Devices)
> **Manufacturer Status**: Abandoned

## Overview

The original crowdfunded smartwatch line. Pebble shut down in 2016, but in 2025 the firmware was open-sourced 100%, Rebble runs the appstore, and Core Devices ships new compatible hardware. Full local control.

## Protocol Summary

The Pebble Protocol: endpoint-addressed packets over Bluetooth serial, a port-9000 WebSocket developer connection, or QEMU (via libpebble2). One connection at a time.

See `device-specs/devices/pebble-smartwatch.yaml` for the full machine-readable spec.

## References

- <https://libpebble2.readthedocs.io/en/latest/protocol/>
- <https://rebble.io/>
- <https://ericmigi.com/blog/pebble-watch-software-is-now-100percent-open-source/>
