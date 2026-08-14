# Sony Smart Tennis Sensor (SSE-TN1) — Research Notes

## What it is
Sony's racket-butt-mounted BLE tennis sensor (SSE-TN1/SSE-TN1W, 2014–2015, ~$199).
Records shot type, ball speed, swing speed, spin, and impact position; syncs to the
"Smart Tennis Sensor" Android/iOS app by Sony Network Communications.

## Why it is abandoned
- Sony terminated the Smart Tennis Sensor service on **2021-09-30**; the app was removed
  from the stores and historical data/server sync is gone
  ([Aura Tide Collective, 2026-05-07](https://www.auratidecollective.com/blogs/performance-lab/sony-smart-tennis-sensor-discontinued-alternative-2026)).
- Sony's own support pages confirm the "Server Sync" cloud dependency for data backup
  ([Sony support article 00113751](https://www.sony.com/electronics/support/articles/00113751)).
- Hardware widely available second-hand; 320+ compatible racket models were supported.

## Local BLE feasibility
- Sensor talks BLE to the phone; live mode streams shot events during play.
- **Prior art (gold)**: Sony published an official Apache-2.0 SDK,
  [`sony/smarttennissensorsdk`](https://github.com/sony/smarttennissensorsdk) — developer
  guide + Javadocs for building apps against the sensor. Note: the SDK talked to the
  sensor through a gated "Host App" binary, so raw GATT may still need extraction.
- APK fetched: `com.sony.smarttennissensor` v1.10.0 (final). Dex strings show plain
  `android.bluetooth` usage but **no UUID literals** — GATT UUIDs are likely constructed
  in code or live in native libs (`libathlete.so`, `libenclave_wrapper_jni.so`;
  "enclave" suggests shot-detection runs in a trusted blob — worth a look).
- One custom 128-bit UUID literal found: `188607e4-ae98-4db6-8cce-6624c3015ddd` (role TBD).

## APK details (apkeep, apk-pure)
- Package: `com.sony.smarttennissensor`, version 1.10.0
- SHA-256: `c0fdf35a8fc38ba6da7b654a73b8f75dd00d8b8419ba19d66183567caca9fc30`
- Note: first apk-pure download was truncated; re-download verified as valid zip.

## Open questions
- Extract the GATT table: jadx on `com.sony.smarttennissensor.*` BLE classes, or strings
  on `lib/arm64-v8a/libathlete.so`.
- Did live mode require a Sony account, or only Server Sync backup? Determines whether
  the stock final APK still works locally today.
- The official SDK developer guide may document the Host App IPC protocol — a cheaper
  RE route than raw GATT if the Host App apk can be located.
