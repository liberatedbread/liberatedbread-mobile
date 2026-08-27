# Yale Access / August BLE Locks

> **Status**: Spec Available (unverified) — active; local control needs a cloud-held offline key
> **Protocol**: BLE
> **Manufacturer**: August / Yale (ASSA ABLOY)
> **Manufacturer Status**: Active

## Overview

August / Yale Access smart locks. No official local API, but direct BLE lock/unlock works once a client holds the lock's OFFLINE KEY + slot — which must be synced from an August/Yale cloud account. After that, day-to-day unlock is fully local. yalexs-ble (Home Assistant) is the reference implementation.

## Protocol Summary

Service 0xFE24; secure-write bd4ac613-…, secure-read bd4ac614-…. HAP-derived framing (plaintext 0x06 / encrypted 0x11). Opcodes 0x0A UNLOCK, 0x0B LOCK, 0x02 GETSTATUS. AES-CBC (zero IV) session keyed by the offline key; two-step 8-byte handshake + key slot.

See `device-specs/devices/yale-august-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/Yale-Libs/yalexs-ble>
- <https://www.home-assistant.io/integrations/august/>
