# August / Yale Access BLE Smart Locks — Research Notes

## What it is
August Smart Lock (gen 1–4, Pro) and the Yale Assure / Linus / Doorman / Conexis
lines that run on the shared "August / Yale Access" platform (Assa Abloy owns both
brands). Lock talks BLE to the phone app; optional Connect Wi-Fi bridge for remote.

## Cloud status: alive but at-risk
- Assa Abloy (owner) is very much alive; the cloud is **not** dead.
- However the app estate is in churn: the August app is being merged into the
  "Yale Home" app region by region, and the migration **broke offline-key
  provisioning** for third-party local control: HA issue
  [home-assistant/core#126117](https://github.com/home-assistant/core/issues/126117)
  (Sep 2024) — "Yale Access Bluetooth no longer functioning since moving to Yale Home
  ... doesn't provide anymore offline key".
- The August integration in HA also warned (2025) that an update was required or
  offline-key retrieval "would soon stop working"
  ([home-assistant/core#152102](https://github.com/home-assistant/core/issues/152102)).
- So: local control works today, but the *key-provisioning path* depends on a cloud
  API the vendor keeps changing. Classic at-risk profile.

## Local BLE feasibility: CONFIRMED, fully reverse-engineered
- `yalexs-ble` library (https://github.com/bdraco/yalexs-ble) + Home Assistant
  `yalexs_ble` integration drive these locks over plain BLE, no cloud in the loop
  once you hold the **offline key + slot** for the lock.
- Offline key is issued per-lock by the August/Yale cloud (retrievable via the HA
  `august` integration, debug logs, or app data). One-time cloud dependency at setup;
  see HA forum thread (Aug 2022–2024):
  https://community.home-assistant.io/t/finding-offline-key-using-august-integration/461791
- Hubitat port confirms the same "local-only once you have offline keys" model:
  https://community.hubitat.com/t/release-hubitat-august-yale-ble-service-local-websocket-bridge-drivers/159919
- Commands known: LOCK 0x0B, UNLOCK 0x0A, GETSTATUS 0x02, WRITESETTING 0x03,
  READSETTING 0x04, LOCK_ACTIVITY 0x2D; full status/door-sense/battery enums
  documented in `yalexs_ble/const.py`.

## APK provenance
- Package `com.august.bennu` ("August Home"), latest APK Pure version ~26.13.0
  (versions 25.x–26.x listed). Fetched via apkeep (apk-pure), 2026-08-03.
- SHA-256: `47b3c8fa7d06d52c782db545a6e5906c4d2460881d6905cc5bcebfb43cfe2a90` (99.2 MB bare APK)
- Yale Home app (`com.august.yale`) NOT fetchable via apk-pure (id may differ).
- Static strings confirm the offline-key design: `OfflineKeyData`,
  "Beginning handshake using the offline key...", REST endpoint
  `/ble/sessionkey/{serialNumber}`.

## BLE UUIDs (from APK strings; roles per yalexs-ble)
| UUID | Role |
|------|------|
| `bd4ac610-0b45-11e3-8ffd-0800200c9a66` | Command service (current-gen platform) |
| `bd4ac611-...-0800200c9a66` | Write characteristic |
| `bd4ac612-...-0800200c9a66` | Read/notify characteristic |
| `bd4ac613-...-0800200c9a66` | Secure write |
| `bd4ac614-...-0800200c9a66` | Secure read |
| `e295c550-69d0-11e4-b116-123b93f75cba` | Legacy (gen1/2) August lock service |
| `e295c551`–`e295c554` (same base) | Legacy characteristics |
| `c06c8400-8e06-11e0-9cb6-0002a5d5c51b` | CSR OTA DFU service |
| `bb392ec0-8d4d-11e0-a896-0002a5d5c51b` | CSR OTA-related |
| `0000fe24-0000-1000-8000-00805f9b34fb` | Command service UUID used by yalexs-ble scan/discovery |

## Open questions
- Can an offline key be provisioned **without** the cloud (e.g. sniffed from an
  already-paired phone's BLE handshake)? Would make the locks cloud-independent.
- Legacy `e295c550` protocol coverage for gen1/2 locks is thinner than current-gen.
- Yale Home app package id / APK still needed for non-August-app regions.
