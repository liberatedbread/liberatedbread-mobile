# SESAME (CANDY HOUSE) BLE Locks

> **Status**: Spec Available (unverified) — active; vendor publishes the protocol
> **Protocol**: BLE
> **Manufacturer**: CANDY HOUSE
> **Manufacturer Status**: Active

## Overview

SESAME locks by CANDY HOUSE are developer-friendly: the vendor publishes the full SesameOS3 BLE protocol and open SDKs, and the vendor app runs on the same SDK. Full local lock/unlock/history works with no cloud once the per-device secret is held.

## Protocol Summary

Service 0xFD81; write commands to 16860002-…, notify on 16860003-…. 20-byte segments; item codes 82 Lock, 83 Unlock, 104 Reset. Crypto: SECP256R1 ECDH at registration → device_secret; AES-CMAC session token; AES-CCM payloads with a ±3 s time check.

See `device-specs/devices/sesame-candyhouse-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/CANDY-HOUSE/API_document/blob/master/SesameOS3/bluetooth.md>
- <https://github.com/homy-newfs8/libsesame3bt-core>
- <https://docs.candyhouse.co/>
