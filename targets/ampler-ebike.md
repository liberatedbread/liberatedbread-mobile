# Ampler e-bikes (Curt, Stout, Axel, Juna, Stellar, Nova) — target spec starter

## Target metadata
- target_id: ampler-ebike
- app package_id(s): TBD on Android ("Ampler Bikes", Android 7+); iOS App
  Store id 1494465020
- device class: city e-bike with an in-frame drive and an app-paired
  controller (BLE; newer bikes also carry LTE-M for tracking)
- transport(s): BLE (phone-direct) for assist settings and lock; LTE-M to
  the vendor cloud for GPS/theft features
- local-only viability: **unknown** — no public protocol work found
  (2026-10-11). The app's local features (assist level, motor
  customisation, lights, lock) are what a spec would cover; GPS tracking is
  cloud and out of scope.

## Why now
- Ampler Bikes OÜ (Tallinn) filed for bankruptcy around 2026-05-15
  ([ERR News](https://news.err.ee/1610024830/estonian-electric-bicycle-maker-ampler-bikes-files-for-bankruptcy));
  German owner forums report support ending. Whether the app's sign-in
  still works, and for how long, is unknown.

## Known facts (public)
- Vendor support pages describe BLE pairing from the app and say the app
  needs location + "Nearby devices" permissions on Android
  ([support article](https://support.amplerbikes.com/en/support/solutions/articles/43000681760-connecting-the-app-to-the-bike-via-bluetooth)).
- The vendor tech page describes "motor and assist customisation via
  Bluetooth LE and LTE-M", app locking, movement alerts and OTA firmware.
- Drive electronics are Ampler's own (not Bosch/Shimano/Mahle), so no
  existing drive spec in this repo covers them — unlike the Accell brands.

## Device discovery signals
- BLE: unknown. Capture needed.

## Threat model + guardrails
- Owned bikes only. Assist and speed-limit writes: document reading them;
  leave any write that changes the legal assist cut-off out of a spec
  (same rule as the Bosch and Mahle entries).
- The lock/alarm function is anti-theft: never document a bypass.

## First experiments
1) Collect the Android package id; fetch the APK while it is still listed.
2) Static: GATT UUIDs, whether a vendor key or account token gates the link.
3) HCI snoop of pair + assist-level change on an owned bike.

## References (URLs only)
- https://news.err.ee/1610024830/estonian-electric-bicycle-maker-ampler-bikes-files-for-bankruptcy
- https://support.amplerbikes.com/en/support/solutions/articles/43000681760-connecting-the-app-to-the-bike-via-bluetooth
- https://amplerbikes.com/pages/tech
- https://apps.apple.com/app/id1494465020
