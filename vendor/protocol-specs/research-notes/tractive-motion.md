# Tractive MOTION — Research Notes

BLE-only pet activity tracker (no GPS, no cellular) from Tractive. Product line discontinued; app delisted; company (Tractive GmbH, Austria) alive but focused on subscription GPS trackers.

## What it is
- Tractive MOTION: small collar-mounted accelerometer pod (~2015–2017) that logs pet activity ("Pet Points") and syncs to the phone over BLE only — no radio besides BLE, no subscription.
- Distinct from Tractive's GPS products: MOTION is the only Tractive device whose entire data path is local BLE.

## Why it's abandoned / at-risk (dated sources)
- Product discontinued; referred to as "the old collar" with "a dedicated app called Tractive Motion" already in Nov 2017 ([PetGuide](https://www.petguide.com/blog/cat/couple-offers-100000-return-record-breaking-cats/), 2017-11-20).
- Android app `com.tractive.android.motion` is delisted from Google Play; latest version on APKPure is 2.3.0 (verified 2026-08-03). Tractive's current product line and help center cover GPS trackers only.
- Company itself is healthy (500k+ subscribers claimed 2022) — risk is backend deprecation for a legacy product, not company collapse.

## Local BLE feasibility — MODERATE (caveat: app account)
- The tracker-to-phone sync is plain BLE GATT with a custom service — recoverable protocol (see YAML).
- The stock app, however, is built around Tractive's cloud: endpoints `graph.tractive.com`, `cdn.tractive.com`, `channel.tractive.com` and login flows are present; historical data/graphs likely require a Tractive account. If the MOTION backend is shut off, the stock app may die while the hardware remains fully readable over BLE — which is exactly the RE opportunity.
- Value of a local client: pull activity samples straight off the pod, no account at all. Feasibility of raw-data readout via the custom service is high (standard GATT notify/read), but unconfirmed without hardware.
- No prior community RE found (searched 2026-08-03).

## APK provenance
- **Package**: `com.tractive.android.motion` ("Tractive MOTION")
- **Source**: apkeep, apk-pure. Versions available: 2.0.0 … 2.3.0; downloaded 2.3.0 (latest).
- **SHA-256**: `704b44ea1b81672df0ffe9113dfd000eaefd3dd54b23d90ff94e9db75205548b` (21 MB, 3 dex files)
- **Framework**: native Java/Kotlin; dedicated `com.tractive.android.motion.ble.MotionClientAPI` BLE class; Nordic UART + DFU references present.

## BLE UUIDs (from classes.dex)
| UUID | Role |
|------|------|
| `69af0002-f994-3a57-749b-0e0aad3fca18` | Custom MOTION data service (`MOTION_DATA_SERVICE`) |
| `69af0003-f994-3a57-749b-0e0aad3fca18` | Custom characteristic (data/notify — role TBD) |
| `69af0004-f994-3a57-749b-0e0aad3fca18` | Custom characteristic (command/write — role TBD) |
| `6e400001`–`6e400004-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART service + RX/TX (+0004, role TBD) |
| `0000180f` / `00002a19` | Battery service / level |
| `0000180a` + `00002a24`–`00002a29` | Device Information (model/serial/FW/HW revision, manufacturer) |
| `0000180d` / `00002a37` | Heart-rate profile referenced (likely shared-library residue — pod has no HR sensor) |
| `0000ffe1`–`0000ffe4` | FFE0-family referenced (role TBD) |

- Constants seen: `MOTION_DEVICE`, `MOTION_HARDWARE_ID`, `MOTION_DFU_SERVICE` (DFU present — likely Nordic buttonless over UART).

## What needs cloud
- Stock app: account/backend for history, graphs, pet profile (`graph.tractive.com`).
- Hardware itself: nothing — activity is stored on-pod and dumped over BLE.

## Open questions
1. Does the 2.3.0 app still function against Tractive's backend today (account creation/login for MOTION)?
2. Frame format on `69af0003/0004` for activity sync and clock set — needs HCI snoop or jadx pass on `MotionClientAPI`.
3. Is the Nordic UART actually exposed by the pod, or only used for DFU?
4. On-pod storage depth (days of activity) and sample format.
