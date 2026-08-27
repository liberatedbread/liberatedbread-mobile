# Xiaomi Mi Band / Amazfit (Huami)

> **Status**: Spec Available (unverified) — active; newer bands need a server key
> **Protocol**: BLE
> **Manufacturer**: Xiaomi / Huami (Zepp Health)
> **Manufacturer Status**: Active

## Overview

Xiaomi/Huami (Zepp) bands and watches. Driven locally over BLE once an auth key is known; newer devices need the key extracted once from the official app. Gadgetbridge is the definitive implementation.

## Protocol Summary

Mi Band 2+ auth characteristic 00000009-0000-3512-2118-0009af100700: a three-step AES-ECB handshake ({0x01,0x08,key} → request random → AES-ECB(random)). Older bands use the FEE0 service.

See `device-specs/devices/xiaomi-huami-miband.yaml` for the full machine-readable spec.

## References

- <https://codeberg.org/Freeyourgadget/Gadgetbridge>
- <https://codeberg.org/Freeyourgadget/Gadgetbridge/wiki/Huami-Server-Pairing>
- <https://leojrfs.github.io/writing/miband2-part1-auth/>
