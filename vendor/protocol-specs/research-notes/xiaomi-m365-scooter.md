# Xiaomi M365 / Mi Scooter Family — BLE Research Notes

## What it is
Xiaomi's M365 (2017), M365 Pro, 1S, Essential/Lite, Pro 2 — the archetypal BLE e-scooter.
Companion app: Xiaomi Home (com.xiaomi.smarthome). Scooters connect over BLE for lock,
speed modes, cruise, telemetry, and firmware.

## Cloud status — product abandoned, vendor alive
- Xiaomi is alive; the M365 line itself is long discontinued (out of sale in NA/EU for
  years; [riderguide.com](https://riderguide.com/best-rated/xiaomi-mi-m365-alternatives/),
  2024: "no longer available in North America").
- Practical friction today: Xiaomi Home demands an account, a region setting, and has
  historically dropped/migrated support for older devices. If Xiaomi delists the scooter
  category, only third-party apps remain — which is fine, because local BLE is the
  better-documented path anyway.
- Security history: the M365's BLE was famously attackable unauthenticated
  ([lanrat.com M365 auth-bypass writeup, 2019](https://lanrat.com/posts/xiaomi-m365/);
  Zimperium 2019 disclosure). Later firmwares added pairing.

## Local BLE feasibility — HIGH (most thoroughly RE'd scooter in existence)
- Full local control with no Xiaomi account via [ScooterHacking Utility](https://wiki.scooterhacking.org/doku.php?id=shutility)
  (settings + firmware flashing over BLE; browser build at utility.cfw.sh).
- Protocol documented in community wikis ([wiki.scooterhacking.org guide-mi](https://wiki.scooterhacking.org/doku.php?id=guide-mi)),
  and re-implemented several times:
  [macbury/m365](https://github.com/macbury/m365) (Rust/btleplug telemetry client),
  [camcamfresh/Xiaomi-M365-BLE-Controller-Replacement](https://github.com/camcamfresh/Xiaomi-M365-BLE-Controller-Replacement)
  (full BLE-controller clone on Particle — proof the whole peripheral side is understood).
- Transport is Nordic UART Service (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`,
  write `6e400002`, notify `6e400003`) carrying the shared Xiaomi/Ninebot serial
  register protocol ([irmo.de teardown](https://www.irmo.de/2023/11/08/e-scooter-bluetooth-hacking/)).

## APK provenance
- Package `com.xiaomi.smarthome` (Xiaomi Home) — multi-device mega-app
- apkeep (apk-pure), XAPK 231,687,100 bytes
- XAPK SHA-256: `12aecd77fd18531e23c7bf43b91ba06b36a8cf7005b31d2fed7645d744ac63b6`
- Static pass skipped: the app is huge and the scooter plugin is a small corner of it;
  the protocol is already fully documented by prior art, so APK RE has low marginal value.
  (This package is already referenced by other notes in this repo for Mi Home devices.)

## What needs cloud
- Nothing for riding or configuration. Firmware images came from Xiaomi's CDN
  (mirrored at firmware.scooterhacking.org). Mi Home device binding is account-based,
  but third-party apps bypass it entirely.

## Open questions
- Per-model pairing differences (M365 Pro 2 / 1S added auth; exact handshake versions
  in SHU sources).
- Whether current Xiaomi Home still pairs M365 (2017) units — report says "verify on
  hardware"; if dropped, that strengthens the abandonment case.

## Safety
Vehicle. Lock/speed/firmware writes are safety-relevant. safety_class: HIGH.
