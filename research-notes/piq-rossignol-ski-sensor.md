# PIQ Robot / Rossignol & PIQ Ski Sensor — Research Notes

## What it is
- PIQ Sport Intelligence (French startup, founded 2015, ex-HTC founders; ~€13M raised from Foxconn/FIH, Orkos, Swisscom, Almaz) built the **PIQ Robot**, a 10 g, 13-axis multisport BLE sensor.
- The **Rossignol and PIQ** pack (announced 2015-12-14, shipped Feb 2016, €149) paired the same sensor with a ski-boot strap and a dedicated Android/iOS app. Ski metrics: edge-to-edge speed, G-force, carving angle, airtime, rotation. Sensor can store a session onboard and sync later.
  - Launch coverage: [designboom 2015-12-15](https://www.designboom.com/technology/rossignol-piq-ski-wearable-tracker-12-14-2015/), [Engadget 2015-12-14](https://www.engadget.com/2015-12-14-rossignol-and-piq-team-up-to-track-your-skiing-performance.html), [MacRumors 2015-12-14](https://www.macrumors.com/2015/12/14/piq-rossignol-ski-sensor/)
  - Hardware: ST BlueNRG BLE SoC, LPS25HB baro, per [Electronic Specifier 2016-01-07](https://www.electronicspecifier.com/products/wearables/st-technology-powers-piq-multi-sport-wearable-sensor/)
- Same sensor also sold as Babolat POP (tennis), Mobitee (golf), Everlast & PIQ (boxing), North PIQ (kiteboard) — one protocol family, many skins.

## Why it's abandoned
- Company went quiet after ~2018; last press is CES 2017-era partnerships. As of **2026-08-04**, `piq.com` redirects to a BrandBucket domain-for-sale page (verified via curl 301 → brandbucket.com/names/piq). Wayback Machine shows the site live through early 2020, then decaying.
- Play Store listing `com.piq.rossignol` returns **404** (verified 2026-08-04). Sister apps (Babolat POP etc.) also gone from Play.
- Sensor firmware updates and account backend are unreachable with the company.

## Cloud dependency — the catch
- The app contains `ActivationActivity` + `ActivationUtils.ServerActivationErrorCode` — pairing a sensor required a **server-side activation** using the "connection code" shipped in the box ([Digital Trends 2016-01-28](https://www.digitaltrends.com/wearables/piq-rossignol-connected-ski/)). With the cloud dead, the stock app cannot activate new sensors.
- **Local feasibility**: the BLE GATT schema is fully recovered (below) and shows a simple command + dual data-packet channel design with no crypto visible at triage depth. A local client that skips app-level activation and talks GATT directly is the liberation path. Whether the *sensor firmware itself* enforces an activated flag is UNKNOWN (open question).

## APK Provenance
- **Package**: `com.piq.rossignol` ("Rossignol and PIQ")
- **Source**: apkeep, `apk-pure` (Play listing dead; APKPure lists builds 2.0.581–3.0.616, other mirrors up to 3.2.1.721)
- **APK SHA-256**: `a1628a7b588f8992adb67e65c18c975bc1e535cecdf72d95363dca1034ac156b` (51.8 MB)
- **Framework**: native Java (app code under `com.octonion.*` — Octonion was PIQ's tech entity), lightly obfuscated

## BLE UUIDs (from `com/octonion/android/common/source/ble/protocol/BleSchema.java`)
| UUID | Role |
|------|------|
| `01000000-0000-0000-0000-000000000080` | Primary service |
| `02000000-0000-0000-0000-000000000080` | dataPacket1 (notify) |
| `03000000-0000-0000-0000-000000000080` | dataPacket2 (notify) |
| `04000000-0000-0000-0000-000000000080` | command (write) — primary device |
| `05000000-0000-0000-0000-000000000080` | fwImage (OTA) |
| `06000000-0000-0000-0000-000000000080` | command variant — secondary device |

App distinguishes master/slave sensor roles (`SensorUtils.getScanFilterMaster/Slave`) — the multisport platform supported dual-sensor setups. Scan is by custom `BleScanner.ScanFilter` with firmware flavors, not a fixed name prefix; advertising name TBD (likely "PIQ").

## Protocol notes
- Packet layer: `PacketFormatter`, `BleClient`/`BleClient6Plus`, motion data dispatched via `motiondispatchers/`; time sync via `GlobalToLocalTimeConverter`/`SensorTimeCorrector`.
- No Nordic UART — fully custom 128-bit UUIDs (unusual `...0080` suffix family).

## Open questions
1. Does firmware refuse streaming before server activation? (Needs a live sensor + nRF Connect.)
2. Advertising name / service-UUID-in-adv (needed for a scanner).
3. Frame format on dataPacket1/2 (raw IMU vs processed metrics).
4. Do sibling apps (Babolat POP `com.piq.babolat.playpop`) share the exact schema? Likely yes — cheap cross-check.

## Status
- APK acquired: yes. Decompiled (jadx): yes (triage). UUIDs: recovered. Protocol frames: not recovered (HCI snoop needed).
- safety_class: LOW (ski performance metrics; no medical/vehicle control).
