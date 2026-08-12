# BlueSmart mia Smart Bottle Sleeve — Research Notes

## What it is
BlueSmart mia (BlueSmart Technology Corp., Hong Kong; founded by
Gisela Xie — unrelated to the Bluesmart luggage company) is a smart
sleeve that slips over a baby bottle: load cell estimates milk intake
(ml), plus milk-temperature alert, feeding-angle guidance, feeding timer,
and expiration warning. mia 2 added wireless charging. All device data
flows over BLE to the app; the app syncs history to BlueSmart's cloud.

## Why it's abandoned (dated sources)
- Verified 2026-08-04: `bluesmartmia.com` is now a generic SEO spam blog
  (AI-generated health/SEO/home-improvement posts) — company domain dead.
- Latest Android app v3.6.3 (versionCode 363); app delisted from Google
  Play; no updates in years. Product long "currently unavailable" on
  Amazon; press/blog coverage stops after ~2019
  (e.g. https://www.motherandbaby.com/reviews/first-year-products/intelligent-baby-feeding-monitor-bluesmart-mia/, 2019-07).
- Crunchbase still lists "Active" — stale; contradicts the dead domain.

## APK Provenance
- **Package**: `com.bluesmart.mia` v3.6.3, 43.5 MB
- **Source**: apkeep (APKPure mirror). First download was a truncated zip;
  re-download verified intact (1766 files).
- **SHA-256**: `6a736d060999e957af5040669e578157a00c06b4cc4158464b219fabf531cd64`
- jadx decompile OK (workspace/static/bluesmart-mia). Chinese-developed
  app (log strings in Chinese), built on the open-source ViseBLE library
  (`com.vise.baseble`); unobfuscated package `com.bluesmart.mia`.

## BLE findings from static analysis
All GATT constants live in `com/bluesmart/mia/app/Constants.java`:

| UUID | Role |
|------|------|
| `0000ffa0-0000-1000-8000-00805f9b34fb` | SERVICE_DEVICE_STATUS (main service) |
| `0000ffa1-0000-1000-8000-00805f9b34fb` | Device exception / SN read (used during pairing) |
| `0000ffa2-0000-1000-8000-00805f9b34fb` | CHARACTER_SYSTEM_TIME (write, uint32 LE seconds) |
| `0000ffa3-0000-1000-8000-00805f9b34fb` | SERVICE_DEVICE_BATTERY (read) |
| `0000ffa4-0000-1000-8000-00805f9b34fb` | Calibration/"K" value read |
| `0000ffa9-0000-1000-8000-00805f9b34fb` | Timezone write (uint32 LE, GMT offset × 3600) |
| `0000ffd0-0000-1000-8000-00805f9b34fb` | mBabyService (mia2 feeding-data service) |
| `0000ffd1/ffd2/ffd3-...` | Feeding-data characteristics |
| `0000ffd4-0000-1000-8000-00805f9b34fb` | mBabyCharacteristic (main feeding data channel) |
| `0000ffd5-0000-1000-8000-00805f9b34fb` | Feeding characteristic (aux) |
| `f000ffc0-0451-4000-b000-000000000000` | TI OAD service (mia2 firmware update, `Mia2OADUpdateActivity`) |

- Device SN derived from the advertised BLE name: `"mia-" + <suffix>`
  (`BleDeviceScanActivity`, `ByteUtils.getMiaSn(device.getName())`).
- App syncs device clock/timezone on every connect (ffa2/ffa9 writes),
  then reads feeding records and uploads them to the cloud
  (`DaemonService`/`BleDaemonService`, log tag `mia2Service`).

## Local feasibility: CONFIRMED-connectable, protocol hypothesis
The device is a plain BLE GATT peripheral with 16-bit UUIDs; clock-set,
battery, calibration, and feeding-data reads/writes are all local GATT
operations — only history sync/push needs the cloud. A replacement client
can: scan for name `mia-*`, connect, write time (ffa2) + timezone (ffa9),
read battery (ffa3), subscribe/read feeding records (ffd0 service).
Payload encoding of the feeding records is not yet decoded (one HCI
snoop, or read `DaemonService` parsing code — ~1–2 h more work).

## What needs cloud
Account, multi-caregiver sync, push alerts ("Mia失联 / lost >24h"),
feeding-history charts. None of that is required to pull live weight/
temperature from the sleeve.

## Open questions
- Exact feeding-record frame format on ffd4 (weight, temperature, angle,
  duration fields).
- Whether ffa1 read enforces any pairing/binding token.
- Milk-temperature threshold semantics (alert computed on-device or in app?).

## Safety
LOW — read-only feeding telemetry. Milk-temperature alerts are advisory;
a replacement client should present measured values verbatim.
