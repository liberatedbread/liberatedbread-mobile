# Wilson X Connected Basketball — Research Notes

## What it is
Wilson X Connected Basketball (2015, ~$200): a regulation ball with an embedded
accelerometer + BLE radio that detects shot makes/misses in-ball (no hoop hardware) and
streams shot events to the "WILSON X BASKETBALL" app. Teardown:
[Fictiv, 2015-12-09](https://www.fictiv.com/teardowns/wilson-x-connected-basketball-teardown)
("Bluetooth LE and an accelerometer to track your shooting stats").

## Why it is abandoned
- Product discontinued by Wilson; the app (last version 1.3.8, 2017-12-21 per APKPure) is
  gone from Google Play and the App Store — mirrors only.
- Wilson pivoted its connected-basketball effort to camera-based tracking via the
  HomeCourt partnership ([homecourt.ai/wilson](https://www.homecourt.ai/wilson)), leaving
  the in-ball sensor product line dead.
- App developed for Wilson by "Sstatzz" (package `com.sstatzz.basketball.wilson`).

## Local BLE feasibility
- Shot detection runs on the ball's MCU; the phone is a display/logger. No hoop-side or
  server-side computation needed for core function.
- Cloud features (sharing, leaderboards) are dead, but the core make/miss stream is local BLE.
- UUID literals recovered from dex (v1.3.8), all 16-bit-based:
  - `0000aa80` service family: chars `aa81`–`aa84`, `aa90`–`aa92`
  - `0000fa10`–`fa12`, `fa14`–`fa16` (note fa13 absent)
  - `0000fd40`–`fd44`
  - plus CCCD `2902`, HID `1812`, PnP-related `1132`–`1134`
- No public community RE found — new work, but a small, old, unobfuscated app.

## APK details (apkeep, apk-pure)
- Package: `com.sstatzz.basketball.wilson`, version 1.3.8 (final)
- SHA-256: `6ea41878d65aa99172b4065a2791721bb58d3f0fdf62bce3a595e58e35e14781`

## Open questions
- Which of the three UUID families is the ball's GATT (aa80 vs fa10 vs fd40) — jadx the
  app's BLE manager or nRF Connect scan of a live ball.
- Whether app login/account is required before shot tracking starts.
- Ball wakes on motion/bounce — confirm advertising name prefix with a scan.
