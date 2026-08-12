# PulsePet GoBone — Research Notes

App-enabled "smart bone" dog toy (wheeled, treat-dispensing). Company dead; control is local BLE.

## What it is
- GoBone: motorized bone-shaped dog toy by PulsePet Inc. (Dallas, TX). Kickstarter 2016, shipped 2017; on Oprah's Favorite Things 2017 ([Dallas Innovates](https://dallasinnovates.com/dallas-based-gobone-finds-a-spotoprahs-christmas-list/), 2017-11-22).
- Manual joystick-style driving from the app plus auto-play modes with configurable schedules ("AutoPlaySettings"); treat compartments in the wheels.
- Connectivity: Bluetooth only ([Digital Trends](https://www.digitaltrends.com/home/gobone-petpulse-smartbone/); [user guide PDF](https://m.media-amazon.com/images/I/617ps2e0lvL.pdf)).

## Why it's abandoned (dated sources)
- `pulsepet.com` is a parked "domain for sale" page (verified 2026-08-03).
- Android app `com.pulsepet.gobone` is delisted from Google Play; latest version on APKPure is 1.3.13 (verified 2026-08-03).
- No product or company activity found after ~2018 press coverage.

## Local BLE feasibility — STRONG
- The toy has no Wi-Fi; all control is phone ↔ toy over BLE.
- App classes are unobfuscated (`com.pulsepet.gobone.controller.*`, `GoBoneBLEManager`) with explicit constants `GOBONE_SERVICE_UUID`, `GOBONE_RX_CHARACTERISTIC_UUID`, `GOBONE_TX_CHARACTERISTIC_UUID` mapping to the standard Nordic UART profile.
- App uses BLE bonding (dedicated `bonding/Bonding` controllers) — a replacement client likely needs to pair/bond.
- Cloud bits present (Firebase, Google Fit scopes) appear to back optional activity tracking; core driving looks offline — confirm on-device. No forced login observed in static pass, but not ruled out.
- No prior community RE found (searched 2026-08-03).

## APK provenance
- **Package**: `com.pulsepet.gobone` ("GoBone")
- **Source**: apkeep, apk-pure. Versions available: 1.0.0, 1.3.13; downloaded 1.3.13 (latest).
- **SHA-256**: `892008f4141c6f717f73cba9ea74acca8954725d016b355e3fab8a8db83b04b2` (12 MB bare APK)
- **Framework**: native Java, unobfuscated; Nordic BLE manager + Nordic DFU library; Firebase/Google Fit SDKs.

## BLE UUIDs (from classes.dex)
| UUID | Role |
|------|------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | `GOBONE_SERVICE_UUID` — Nordic UART service |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | `GOBONE_RX_CHARACTERISTIC_UUID` — write to toy |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | `GOBONE_TX_CHARACTERISTIC_UUID` — notify from toy |
| `0000fe59-0000-1000-8000-00805f9b34fb` | Nordic Secure DFU (buttonless) service |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery service |
| `00002a19-0000-1000-8000-00805f9b34fb` | Battery level characteristic |

## What needs cloud
- Nothing for driving/auto-play, as far as static analysis shows. Firebase/Google Fit only used for activity-history features (hypothesis — verify on first app launch).

## Open questions
1. UART command format (drive vectors, auto-play config, LED/sound) — small unobfuscated codebase; a short jadx pass on `GoBoneBLEManager` should yield the full command set without hardware.
2. Is bonding strictly required, or will a bond-less write work?
3. Whether app first-run forces account creation (Firebase present; unverified).
