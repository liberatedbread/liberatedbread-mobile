# TTLock / Sciener BLE Locks

> **Status**: Spec Available (unverified; RE partial) — active platform, hundreds of OEM rebadges
> **Protocol**: BLE
> **Manufacturer**: Sciener (TTLock platform) — rebadged by hundreds of OEMs
> **Manufacturer Status**: Active

## Overview

TTLock is a white-label BLE lock stack by Sciener, rebadged by many OEMs (generic smart deadbolts, padlocks, cabinet locks). Sciener ships a closed SDK and a cloud but not the wire protocol; the community has partially reverse-engineered it. Local lock/unlock works once a client holds the lock's per-lock credential set from initialisation — the 16-byte AES key and the numeric unlock key, plus the admin passcode for admin operations such as passcode management — together with the lock's frame-header values (most V3 locks: protocol type 5, sub-version 3, scene 2, group 1, org 1). The maintained [ha-ttlock-ble](https://github.com/roquerodrigo/ha-ttlock-ble) integration reports working local control from such keys, including hand-entered ones with no TTLock account; it does not initialise locks itself. The older kind3r add-on that does pair/reset locally is unmaintained by its author's own account. A public cloud-side security teardown found severe flaws (see the spec's security advisory).

## Protocol Summary

GATT command write on 0000fff2, notify on 0000fff4. Frame [12B header (magic 7F 5A)][data][CRC-8/MAXIM][CRLF]; data is AES/CBC/PKCS5 with IV=key, plus a pre-AES XOR obfuscation. Advertised name encodes the reversed last-6-MAC. Manufacturer data reportedly carries the protocol type/sub-version/scene, bolt position and battery, so state can be tracked without connecting (byte layout not yet recorded). Firmware images are served per lock by the vendor cloud; no public image is known.

See `device-specs/devices/ttlock-sciener-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/Fusseldieb/ttlock-reverse-engineering>
- <https://nv1t.github.io/blog/the-weired-ble-lock/>
- <https://github.com/ttlock/Android_SDK_Demo>
- <https://github.com/roquerodrigo/ha-ttlock-ble>
- <https://github.com/kind3r/hass-addons> (historical; unmaintained)
