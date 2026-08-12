# pHin Smart Pool/Spa Monitor (ConnectedYard → Hayward) — Research Notes

## What it is
Floating pool/hot-tub water monitor (pH, ORP/sanitizer, temperature) plus a Wi-Fi
bridge and mobile app. Made by ConnectedYard Inc. (Silicon Valley), acquired by
Hayward Industries in April 2018. The floater talks BLE; the bridge (and the
phone app) are its BLE clients.

## Why it's abandoned (confirmed, dated sources)
- Hayward acquired ConnectedYard 2018-04-11 ([poolspanews](https://www.poolspanews.com/business/hayward-acquires-phin_o)).
- Hayward discontinued pHin effective **2021-12-20**; servers shut down that date
  ([PoolPro, 2021-12-21](https://poolpromag.com/hayward-buys-phin/),
  [Hubitat thread](https://community.hubitat.com/t/smart-pool-monitor-phin/44654?page=2)).
- By Dec 2022 the app was "completely shut down" and phin.co itself was gone
  ([iopool blog, 2022-12-16](https://iopool.com/blogs/connected-objects/phin-alternative)).
- Cloud required an active subscription; hardware is bricked without a local path.

## APK Provenance
- **Package**: `com.connectedyard.phin` ("pHin Smart Water Monitor"), version 4.0.1 (latest on APKPure)
- **Source**: apkeep, `-d apk-pure` → XAPK (split APKs)
- **XAPK SHA-256**: `9c6b7945c9cd950212670511092d6e9d368aa5e31490200eecb8e4af09596119`
- **App framework**: Native Java/Kotlin, RxJava; moderately obfuscated (core app
  package `com.connectedyard.phin` readable; BLE layer obfuscated to `a3`/`b3`/`w2`).

## BLE details recovered (jadx triage of base APK)
The app runs a foreground `PhinBleService` that scans for pHin devices and builds
monitor objects **directly from BLE advertisement bytes** (`b3/b.java` parses five
packed 32-bit fields from the advert, plus an 8-byte calibration record with
bit-packed mV-style values scaled /10). This strongly suggests the floater
broadcasts raw sensor data in advertisements — i.e. readings can be sniffed
passively, no pairing or cloud needed.

### pHin monitor UUIDs (`a3/c.java`, "PhinMonitor.java")
| UUID | Role |
|------|------|
| `0000fe63-0000-1000-8000-00805f9b34fb` | 16-bit service UUID (advertised; scan filter, also in `f3/c.java` as `fffffe63-...`) |
| `3206152c-76fd-4996-952b-2a1be2cb9450` | Characteristic (field `G`) |
| `32061527-76fd-4996-952b-2a1be2cb9450` | UUID referenced (likely monitor service) |
| `32061523-76fd-4996-952b-2a1be2cb9450` | UUID referenced (characteristic) |

### pHin bridge UUIDs (`a3/a.java`, "PhinBridge.java")
| UUID | Role |
|------|------|
| `c92c815e-a812-4b99-896e-87cd27720000` | Bridge service |
| `c92c815e-a812-4b99-896e-87cd2772000b`–`...20016` | Bridge characteristics (Wi-Fi provisioning, status, etc.) |
| `0000180a`/`2a24`/`2a26`/`2a27`/`2a25` | Standard Device Information |

App also contains a `DfuService` (Nordic DFU) and `SetupBridgeBleViewModel`
(BLE-only bridge Wi-Fi provisioning — no cloud needed for that step).

## Corroboration from a second app
iopool (competitor) offered "link your pHin device to the iopool app" after the
shutdown. The iopool APK (v2.43.6) string table contains pHin's `3206152C-...`
characteristic and `0000fe63` service UUID — independent confirmation that pHin
hardware is readable over plain BLE by third-party software.

## Local feasibility verdict
**Confirmed feasible (medium difficulty).** No pairing/auth visible in the scan
path; adverts appear to carry the payload. What needs mapping: advert byte
layout → pH/ORP/temp, and the calibration record math. HCI snoop of the iopool
app (still maintained, reads pHin) or of an archived pHin 4.0.1 install against a
live floater is the fastest route.

## What needed cloud (now gone)
- Account, history, dosing recommendations, and likely the conversion from raw
  electrode mV to "sanitizer ppm" (calibration constants were synced per-device).
- Chemical subscription store.

## Open questions
- Exact advert/manufacturer-data layout and company ID.
- Whether GATT connect on `3206152c` yields richer data (history?).
- Electrode conditioning requirements after years of shelf time.

## Safety class
LOW — water chemistry advisory readings; not medical, no actuator control.
