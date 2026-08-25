# TTLock / Sciener BLE Locks

> **Status**: Spec Available (unverified; RE partial) — active platform, hundreds of OEM rebadges
> **Protocol**: BLE
> **Manufacturer**: Sciener (TTLock platform) — rebadged by hundreds of OEMs
> **Manufacturer Status**: Active

## Overview

TTLock is a white-label BLE lock stack by Sciener, rebadged by many OEMs (generic smart deadbolts, padlocks, cabinet locks). Sciener ships a closed SDK and a cloud but not the wire protocol; the community has partially reverse-engineered it. Local unlock works once a client holds the lock's per-lock AES key (obtained after pairing). A public cloud-side security teardown found severe flaws (see the spec's security advisory).

## Protocol Summary

GATT command write on 0000fff2, notify on 0000fff4. Frame [12B header (magic 7F 5A)][data][CRC-8/MAXIM][CRLF]; data is AES/CBC/PKCS5 with IV=key, plus a pre-AES XOR obfuscation. Advertised name encodes the reversed last-6-MAC.

See `device-specs/devices/ttlock-sciener-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/Fusseldieb/ttlock-reverse-engineering>
- <https://nv1t.github.io/blog/the-weired-ble-lock/>
- <https://github.com/ttlock/Android_SDK_Demo>
