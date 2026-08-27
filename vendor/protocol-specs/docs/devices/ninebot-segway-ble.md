# Ninebot / Segway E-Scooter (BLE)

> **Status**: Spec Available (unverified) — active; newer firmware adds session crypto
> **Protocol**: BLE
> **Manufacturer**: Ninebot-Segway
> **Manufacturer Status**: Active

## Overview

Ninebot/Segway ES and MAX (G30) scooters use the same Nordic-UART serial-over-BLE bridge and register model as the Xiaomi M365 (see that spec); only the outer frame differs. Newer G30 firmware is reported to add AES session encryption.

## Protocol Summary

Nordic UART service 6e400001-…; write 6e400002, notify 6e400003. Frame header 5A A5 (vs Xiaomi 55 AA), length, addresses, command, payload, 2-byte LE checksum. Register model shared with the M365.

See `device-specs/devices/ninebot-segway-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/Informatic/py9b>
- <https://github.com/CamiAlfa/M365-BLE-PROTOCOL>
