# JBD / Xiaoxiang Smart BMS (BLE)

> **Status**: Spec Available (unverified) — active; ships in countless LiFePO4 packs
> **Protocol**: BLE
> **Manufacturer**: Shenzhen Jiabaida (JBD) — many LiFePO4 pack rebrands (Overkill Solar, LIONTRON, ECO-WORTHY, ...)
> **Manufacturer Status**: Active

## Overview

JBD (Xiaoxiang) battery-management systems inside many rebranded LiFePO4 packs (Overkill Solar, LIONTRON, ECO-WORTHY). Local BLE/UART, no cloud.

## Protocol Summary

GATT service 0xFF00 (notify 0xFF01, write 0xFF02); frames `0xDD ... checksum 0x77`. Read 0x03 basic info (voltage, current, SOC, FET status, temps), 0x04 cell voltages; writes toggle FETs/balancer in factory mode.

See `device-specs/devices/jbd-xiaoxiang-bms-ble.yaml` for the full machine-readable spec.

## References

- <https://gitlab.com/bms-tools/bms-tools/-/blob/master/JBD_REGISTER_MAP.md>
- <https://github.com/syssi/esphome-jbd-bms>
- <https://github.com/kolins-cz/Smart-BMS-Bluetooth-ESP32>
