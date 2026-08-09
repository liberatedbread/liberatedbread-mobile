# Lockitron Bolt — Research Notes

## What it is
Lockitron Bolt (2015, Apigy Inc., Y Combinator alum) — $99 retrofit deadbolt,
**BLE-only** (Nordic nRF51822 SoC), optional "Bridge" (Electric Imp Wi-Fi +
BlueGiga BLE112) for remote, optional Keypad. One of the earliest BLE smart locks.

## Cloud status: DEAD
- Early 2019: Chamberlain Group acquired Lockitron (with Tend) for the myQ
  platform: https://techcrunch.com/ (via Wikipedia, Apigy acquisition)
- **2020-06-17**: Lockitron system shut down (vendor announcement, Facebook/
  Twitter posts; see Wikipedia): https://en.wikipedia.org/wiki/Lockitron
- Per Wikipedia: "Lockitron Bolt can still be controlled on the myQ platform" —
  i.e. residual support exists only through Chamberlain's myQ **cloud**; whether
  that still works in 2026 is unverified. Original Lockitron app/API
  (api.lockitron.com) are gone.

## Local BLE feasibility: plausible hardware, no public RE
- nRF51822-based, BLE GATT; the lock historically paired and operated over BLE
  with the phone app (Bridge only added remote access), so a local BLE control
  path physically exists.
- No public reverse-engineering of the Bolt BLE protocol was found (no GitHub
  drivers, no HA/Gadgetbridge support). Greenfield RE target.
- Pairing model unknown — the crux question is whether pairing/keys can be
  established without the dead Lockitron backend (app likely fetched per-lock
  keys from the cloud, cf. August offline keys). If keys live only server-side,
  already-paired locks may be recoverable only by sniffing a paired phone;
  factory-reset locks may be unprovisionable.

## APK: NOT FETCHED
- Removed from Google Play years ago; not on APK Pure under any plausible id
  (`com.lockitron`, `com.lockitron.lockitron`, `lockitron.com.lockitron`,
  `com.lockitron.mobile` all miss, 2026-08-03).
- Next places to look: APKMirror archive, Wayback captures of the Play listing,
  or an old phone backup. Without the APK, RE difficulty is HIGH (would need
  firmware dumping from the nRF51822 or myQ-app analysis if the myQ app still
  contains Bolt support).

## Open questions
- Does the myQ path still function (cloud) and does the myQ app pair Bolt over
  BLE locally?
- Was the Bolt pairing key exchange phone-local (app-generated) or server-issued?
- Any surviving Lockitron APK in the wild.
