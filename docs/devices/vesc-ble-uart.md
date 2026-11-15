# VESC (open motor controller)

> **Status**: Spec Available (unverified) — active; open by design
> **Protocol**: BLE
> **Manufacturer**: Benjamin Vedder & community
> **Manufacturer Status**: Active

## Overview

VESC is the open-source motor-controller firmware powering many DIY e-skateboards, EUCs and scooters, plus the VESC Express BLE add-on. The COMM packet protocol and BLE bridge are the project's own open source — nothing reverse-engineered.

## Protocol Summary

Nordic UART service 6e400001-…; write 6e400002, notify 6e400003. COMM packet: 02/03/04 start, length, payload, CRC16 (big-endian), 0x03 stop. Command ids: 4 GET_VALUES, 5 SET_DUTY, 6 SET_CURRENT, 8 SET_RPM, 34 FORWARD_CAN. No auth by default (safety).

See `device-specs/devices/vesc-ble-uart.yaml` for the full machine-readable spec.

## References

- <https://github.com/vedderb/bldc>
- <https://github.com/vedderb/vesc_express>
