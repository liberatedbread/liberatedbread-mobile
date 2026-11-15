# Xiaomi M365 E-Scooter (BLE)

> **Status**: Spec Available (unverified) — active; the most RE'd scooter (unauthenticated BLE — see advisory)
> **Protocol**: BLE
> **Manufacturer**: Xiaomi (Ninebot-built ESC/BMS)
> **Manufacturer Status**: Active

## Overview

The Xiaomi M365 (and the ESC/BMS shared with Ninebot-built variants) is the most reverse-engineered e-scooter. Its BLE module is a Nordic UART port bridging a one-wire UART bus shared by the BLE module, ESC and BMS. Fully local. Note: commands are unauthenticated over BLE (Zimperium advisory).

## Protocol Summary

Nordic UART service 6e400001-…; write 6e400002, notify 6e400003. Frame 55 AA | L | D | T | payload | ck0 ck1 (checksum = sum XOR 0xFFFF). Registers: 0xB4 battery %, 0xB5 speed, 0x7C cruise; BMS via D=0x22.

See `device-specs/devices/xiaomi-m365-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/CamiAlfa/M365-BLE-PROTOCOL>
- <https://github.com/Informatic/py9b>
- <https://www.zimperium.com/blog/dont-give-me-a-brake-xiaomi-scooter-hack-enables-dangerous-accelerations-and-stops-for-unsuspecting-riders/>
