# FOBO Bike 2 / FOBO Tire (Salutica) BLE TPMS — Research Notes

## What it is
FOBO is a family of Bluetooth tire-pressure monitoring systems by Salutica Allied
Solutions (Malaysia): FOBO Tire / Tire 2 / Tire Lite (cars), FOBO Bike / Bike 2
(motorcycles), FOBO Wheely (wheelchairs). BLE 5.0 cap sensors (CR1632), optional
In-Car relay unit. Sensors talk BLE directly to the phone app.

## Why it is at-risk (cloud-dependent, app churn)
- App **requires account sign-in** (Google or email) before use — confirmed in the
  current user manual ("Launch FOBO TPMS app and sign in using Google or your
  personal...") and in the FOBO Bike 2 APK (`LoginActivity` uses Google Sign-In +
  email, plus `TwoFactorLoginActivity`). Sensor ownership is bound to the account
  ("CrossPair" anti-theft; owner must release sensors server-side for transfer).
  If Salutica's auth/fleet server dies, new installs and sensor re-pairing die too.
- The old **FOBO Bike 2 app is delisted from Google Play** (Play URL for
  `my.com.salutica.fobobike2` returns 404, verified 2026-08-04). Forum reports
  (GL1800Riders, 2026-03) say FOBO Bike 2 app is "discontinued and unsupported in a
  few months", replaced by the new consolidated "FOBO TPMS" app (v1.6.x at the time).
- Vendor is a small ODM; community reports of the FOBO site being down (SpyderLovers,
  2025-07-25). Site was back up as of 2026-08-04, but the pattern is fragile.

Sources:
- https://my-fobo.com/manual/FOBO_BIKE_2_USER_MANUAL_V2.1.01747645153.pdf
- https://www.gl1800riders.com/threads/fobo-tpms-updates-tire-pressure-monitoring.497322/ (2026-03)
- https://www.spyderlovers.com/threads/it-looks-like-the-fobo-tpms-site-has-gone-belly-up-just-letting-you-know.164443/ (2025-07)
- https://play.google.com/store/apps/details?id=my.com.salutica.fobotpms (live listing, new app)

## APK provenance
| App | Package | Version | SHA-256 | Source |
|-----|---------|---------|---------|--------|
| FOBO Bike 2 (delisted) | `my.com.salutica.fobobike2` | 2.4.13 (214) | `1c196b324a3c01419cd01bd0d599672202ca0a92cb2a7e4a9dfb837433e2104d` | apkeep / apk-pure |
| FOBO TPMS (current) | `my.com.salutica.fobotpms` | 1.9.1 (312), XAPK | `bf7ea5db2e3fd0bc3011b1d4579c90b90c7ae4db9155e3752375ebc96d4f8a37` | apkeep / apk-pure |

## BLE findings (static, FOBO Bike 2 v2.4.13 via jadx)
UUID constant table in `m4/AbstractC1480b.java` (deobfuscated view in
`$REPO/workspace/static/fobo-bike2/`):
- Custom 16-bit service families: `fba0` (chars `fba1`), `fbb0` group
  (`fbb0`–`fbb4`, `fbe7`), `fab0`/`fab2`, `fad0`/`fad3`, `ee04`/`ee05`/`ee07`/`ee0b`,
  `eefe`/`ee0f` — all `0000xxxx-0000-1000-8000-00805f9b34fb`.
- Standard: 1802 (Immediate Alert, 2a06), 180f (Battery, 2a19), 180a + 2a25/2a26/2a27.
- App contains an `OadActivity` → one family (likely `ee04`) is over-air firmware update.
- Advertising name prefix not pinned down statically (pairing is QR-code/MAC driven);
  needs one nRF Connect scan of a live sensor.

## Local feasibility
Sensors communicate over BLE directly with the phone; all monitoring UI works in
Bluetooth range. The cloud dependency is account auth + sensor ownership binding +
sharing features, not the data path. A local client needs: advert format or GATT
map of the `fba0` service (pressure/temperature/battery/alarm characteristics) +
whatever pairing handshake CrossPair implies. No prior community RE found.

## Open questions
- Do FOBO Bike 2 sensors work with the new FOBO TPMS app long-term, or are they
  being orphaned too?
- Is there a pairing/bonding secret exchanged at install (CrossPair) that a local
  client must reproduce?
- Which service is live pressure data vs OAD?
- Does the FOBO Tire (car) hardware share the same GATT map?

## Safety
TPMS data is safety-adjacent (underinflation warnings) but read-only; no control path.
