# Xiaomi Mi Band / Amazfit (Huami)

> **Status**: Spec Available (unverified) — active; newer bands need a server key
> **Protocol**: BLE
> **Manufacturer**: Xiaomi / Huami (Zepp Health)
> **Manufacturer Status**: Active

## Overview

Xiaomi/Huami (Zepp) bands and watches. Driven locally over BLE once an auth key is known; newer devices need the key extracted once from the official app. Gadgetbridge is the definitive implementation.

## Protocol Summary

Mi Band 2+ auth characteristic 00000009-0000-3512-2118-0009af100700: a three-step AES-ECB handshake ({0x01,0x08,key} → request random → AES-ECB(random)). Older bands use the FEE0 service.

The Mi Band 7 does not have that characteristic. A public HCI capture of a Band 7 and the vendor app (Gadgetbridge issue #2753) shows it authenticating instead over a chunked, later encrypted, channel on 00000016-/00000017-0000-3512-2118-0009af100700 in the FEE0 service, with the key exchange on endpoint 0x0082. The spec's `protocol_details.huami_2021_chunked` records the framing as captured; the key agreement and session encryption are still open questions, so do not send the three-step handshake to a Band 7.

See `device-specs/devices/xiaomi-huami-miband.yaml` for the full machine-readable spec.

## References

- <https://codeberg.org/Freeyourgadget/Gadgetbridge>
- <https://codeberg.org/Freeyourgadget/Gadgetbridge/wiki/Huami-Server-Pairing>
- <https://leojrfs.github.io/writing/miband2-part1-auth/>
- <https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/2753> (Mi Band 7 capture)
