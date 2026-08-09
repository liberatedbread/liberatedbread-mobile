# Beddit 3 / 3.5 Sleep Monitor — Research Notes

Under-mattress sensor-strip sleep tracker. Finnish startup Beddit was acquired by Apple
in May 2017; Beddit 3.5 (BLE 4.2, "Model 3.5") shipped 2018. Category: sleep tracker.

## Why it is abandoned
- Apple killed Beddit Cloud on 2018-11-15 — [AppleInsider, 2018-09-21](https://appleinsider.com/articles/18/09/21/apple-owned-beddit-to-shut-down-cloud-services-on-nov-15). After that the app worked local-only (on-device storage + BLE sync).
- Android support was dropped in 2019; hardware discontinued and pulled from retail in 2022 — [9to5Mac, 2024-09-30](https://9to5mac.com/2024/09/30/apple-removes-beddit-app-store/), [Gadgets & Wearables, 2022-01-12](https://gadgetsandwearables.com/2022/01/12/beddit-sleep-monitor-buy/).
- Apple removed both Beddit apps (3.0 and 3.5) from the App Store in late Sep 2024 — [MacRumors](https://www.macrumors.com/guide/beddit/), [9to5Mac, 2024-09-30](https://9to5mac.com/2024/09/30/apple-removes-beddit-app-store/).

## Local BLE feasibility
- Device worked for ~6 years (2018→2024) with **no cloud**: the app talked to the
  sensor over BLE and stored history locally. This is proven local-only operation.
- The orphaning event is the *app removal*, not a protocol block — a local BLE client
  can fully replace the app. No pairing/cloud bootstrap known.
- No prior community RE found (no HA integration, no GitHub driver) — greenfield.
- **Verdict: strong target.** App (Android, pre-2019) is fetchable and decompiles cleanly.

## APK provenance
- **Package**: `com.beddit.beddit` (legacy Android app, frozen ~2018/2019)
- **Source**: apkeep, apk-pure (2026-08-03)
- **APK SHA-256**: `f3b995c9e1e9c38c27bee95668508b2a2a746f9afd0e9f4e665cca4bd9b3f9f2` (25 MB, single DEX)
- jadx decompile clean; BLE code under `com.beddit.sensor.le` (lightly obfuscated class
  names, but full logic readable).

## BLE UUIDs (recovered from static pass)
From `com/beddit/sensor/le/LESensorSession.java`, `a.java`, `b.java`:

| UUID | Role |
|------|------|
| `e6807e20-b90a-11e5-a837-0800200c9a66` | Beddit sensor data service (v3 hardware) |
| `e6807d21-b90a-11e5-a837-0800200c9a66` | Data channel characteristic (paired with channel-desc e21) |
| `e6807d22-b90a-11e5-a837-0800200c9a66` | Data channel characteristic |
| `e6807e21-b90a-11e5-a837-0800200c9a66` | Channel description (read; ≥5-byte channel descriptor) |
| `e6807e24-b90a-11e5-a837-0800200c9a66` | Data channel characteristic |
| `e6807e25-b90a-11e5-a837-0800200c9a66` | Channel description |
| `f82fd8a8-329d-4c44-a178-e82f91ec9fe6` | Second/legacy service (also in scan state) |
| `f82fd8a9-329d-4c44-a178-e82f91ec9fe6` | Legacy characteristic |
| `f82fd8aa-329d-4c44-a178-e82f91ec9fe6` | Legacy characteristic |
| `0000180a-...` + 2A25/2A26/2A27/2A28 | Device Information (serial, fw, hw, sw rev) — read at connect |

- BT Classic SPP UUID `00001101-...` also present (legacy Beddit 3.0 fallback path?).
- `612d9e68-...` seen in DEX is a Postmark email API token, **not** a BLE UUID.
- Session flow (`b.java`): read DIS → read channel descriptors from service `e6807e20`
  → subscribe to data chars; stream parsing in `com.beddit.sensor` (SensorChannelDetails etc.).
- Hardware type string `HARDWARE_TYPE_IDENTIFIER_BTLE_V3` in `SensorManager`.

## Open questions
- Advertising name pattern (likely "Beddit") — not in DEX strings; needs live scan.
- Channel-descriptor format and stream encoding (piezo + capacitive channels) — readable
  in `com.beddit.sensor` with more time; an HCI snoop of one night sync would nail it.
- Whether the f82fd8a8 service is Beddit 3.0 (pre-Apple) vs 3.5.

## Status
- apk_acquired: yes; apk_decompiled: yes; uuids_recovered: yes; protocol_recovered: partial (roles inferred, frame format TBD).
- Safety class: LOW (passive under-mattress sensor, wellness data only).
