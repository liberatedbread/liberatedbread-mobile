# Cerevo XON SNOW-1 Smart Snowboard Bindings — Research Notes

## What it is
- **XON SNOW-1**: snowboard bindings with 4 load sensors per foot (weight balance/center of gravity), 2 board-flex sensors, and 9-axis IMU; streams 13 data points in real time over **Bluetooth 4.0 LE** to a phone app; LED strips on each binding give on-snow feedback. CES 2015 debut, on sale 2015-12-21 at $579.
  - [Cerevo product page](https://xon.cerevo.com/en/snow-1/), [launch press release 2015-12-21](https://cerevo.com/en/news/2015-12-21_227/index.html), [PCWorld CES 2015](https://www.pcworld.com/article/431121/bluetooth-in-your-snowboard-bindings-meet-the-xon-snow-1.html)
- Micro-USB charging (IPX4), ~7 h battery, M/L sizes.

## Why it's at risk / abandoned
- Manufacturer **Cerevo is alive** (still shipping camera accessories in 2025), but SNOW-1 is on Cerevo's official **discontinued products** page ([cerevo.com/en/products/discontinued](https://cerevo.com/en/products/discontinued/)) and the whole XON smart-sports line is dead.
- Android app `com.cerevo.snow1` ("SNOW-1", last build v1.0.2.18, 2016-11-07) returns **404** on Play (verified 2026-08-04). No updates in a decade; support for the line is over.

## Local feasibility — strong
- App is a **pure local BLE client** — no login or cloud dependency seen at triage depth; settings live in local SharedPreferences (`snow1SharedPreferenceKey`). This is a genuinely local-first device.
- Both bindings advertise separately: name prefixes **`SNOW-1_L`** and **`SNOW-1_R`** (`PairingActivity.java` scans with `name.startsWith(...)`).
- Custom GATT service family recovered from `com/cerevo/snow1/services/BluetoothLeService.java`:

| UUID | Role |
|------|------|
| `58952982-3C22-4A8C-B826-5F50EB52F1FB` | Primary XON service |
| `...EB52F1FC` | Sensor data channel (notify) |
| `...EB52F1FE` | Sensor data channel (notify) |
| `...EB52F1FF` | Data channel (notify) |
| `...EB52F202` | Data channel (notify) |
| `...EB52F203` | Data channel (notify) |
| `...EB52F201` | **Time sync** — app writes `System.currentTimeMillis()/1000` on connect |
| `0000180f` / `00002a19` | Standard Battery Service / Battery Level |
| `0000180a` / `00002a28` | Device Information / SW revision |

- On connect the app: discovers the F1FB service, enables notifications on F1FC/F1FE, and writes epoch time to F201. Five notify channels plausibly map to: load-balance array, flex pair, IMU, status, LED/control feedback (exact mapping TBD — obfuscated but single-purpose app, small code surface: ~1350 classes total, most support libs).

## APK Provenance
- **Package**: `com.cerevo.snow1` ("SNOW-1")
- **Source**: apkeep, `apk-pure`
- **APK SHA-256**: `8f3bd42bf38b4514351140d2bc3fcd0d7317fdb1f6f64888bc17fb493814a843` (7.8 MB)
- **Version**: 1.0.2 (internal string "SNOW-1 v1.0.2.18, Build: 2016-11-07", revision 86dae00)
- **Framework**: native Java, partially obfuscated, small and readable

## Open questions
1. Notify-channel → sensor mapping (needs one live binding or HCI snoop of the app).
2. Whether LEDs/flex-sensor calibration are host-driven (write target not yet found — maybe F1FF or F202 are writeable).
3. Firmware update path (none seen in app — good news, nothing cloud-gated).

## Status
- APK acquired: yes. Decompiled: yes (triage). UUIDs: recovered (service + 6 chars + battery/DIS). Frame format: TBD (HCI snoop needed).
- safety_class: LOW (sports metrics; LED feedback only).
