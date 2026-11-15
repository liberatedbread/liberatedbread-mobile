# LOQED Touch Smart Lock — Research Notes

## What it is
LOQED Touch Smart Lock — Dutch keyless retrofit lock (touch-to-open), BLE to the
phone app, optional LOQED Bridge for Wi-Fi/remote. "LOQED by Shelly" 2S is the
current hardware. Lock itself is BLE; the bridge does Wi-Fi.

## Cloud status: bankrupt 2024, revived under Shelly
- **2024-06-05**: LOQED B.V. filed for bankruptcy — founders' announcement:
  https://loqed.com/en/important-announcement-from-loqed/
- **2024-07-11**: Shelly Group acquired the assets (IP + inventory) out of
  insolvency: https://corporate.shelly.com/corporate-news/eqs-news_2802189_en/
- 2025: relaunched as "LOQED by Shelly"; locks migrated into Shelly app/cloud
  (Shelly corporate news, Apr 2025). Original LOQED cloud kept running
  (support.loqed.com active as of 2026).
- Risk profile: first-gen LOQED owners already lived through one corporate death;
  continuity now depends on Shelly. The documented **local** APIs below are the
  durable path.

## Local control: CONFIRMED (two paths)
1. **Local bridge REST API + outgoing webhooks** (officially documented):
   https://support.loqed.com/en/articles/6127856-loqed-local-bridge-api-integration
   The bridge exposes a local HTTP API (API key generated in the app) and pushes
   state webhooks to a LAN URL — no cloud in the control path.
2. **Direct BLE** phone-to-lock (app works in Bluetooth range without internet).
   Direct-BLE third-party RE is *not* published; UUIDs recovered below are a
   starting point.

## Prior art
- `loqedapi` (Python, local-network API): https://github.com/cpolhout/loqed_custom_component
- HA custom integration: https://github.com/mikewoudenberg/homeassistant-loqed
- Homebridge: https://github.com/marktiddy/homebridge-loqed

## APK provenance
- Package **`com.loqed.keychain`** ("LOQED"),
  version **4.2.86** (versionCode 4286), XAPK via apkeep (apk-pure), 2026-08-03.
- SHA-256 (xapk): `c008a77e5e5f917801e1bb232b4315d6741982dc4db36aec149edfaadd6805c1`
- Min SDK 26, target 35; standard BLE permissions; contains
  `ShellyAdvertisementParser` (post-acquisition Shelly integration).

## BLE UUIDs (from base-APK DEX strings)
| UUID | Notes |
|------|-------|
| `bdce0001-e90d-4685-b89d-5578cd199a9f` | Likely LOQED GATT service |
| `bdce0101-e90d-4685-b89d-5578cd199a9f` | Characteristic (role TBD, write?) |
| `bdce0102-e90d-4685-b89d-5578cd199a9f` | Characteristic (role TBD, notify?) |
| `de8a5aac-a99b-c315-0c80-60d4cbb51225` | Present in DEX; likely scan/advertisement filter UUID |
| `0000fcd2-0000-1000-8000-00805f9b34fb` | CHIPoBLE (Matter-over-BLE commissioning) service — suggests Matter commissioning support in newer firmware; unconfirmed |
| `00002902-0000-1000-8000-00805f9b34fb` | CCCD |

Characteristic roles and the touch-to-open handshake are unconfirmed — needs an
HCI snoop or a jadx pass on the `com.loqed` BLE classes.

## Open questions
- Does the local bridge API survive if Shelly later kills the LOQED cloud
  (bridge firmware already flashed)? Likely yes (API key is local) — verify.
- BLE pairing/key exchange format for direct phone-free control (e.g. ESP32 proxy).
- Whether original (pre-Shelly) bridges can be reflashed or blocked from cloud
  without losing local API.
