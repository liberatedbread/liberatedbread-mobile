# Swimmo Watch — Research Notes

## What It Is
Dedicated swim training watch from Swimmo sp. z o.o. (Poznań, Poland). Kickstarter
April–May 2015 (goal hit in 48 h), shipped from October 2015. 1.3" color OLED,
buttonless "Rotate&Tap" UI, optical HR, stroke detection, PaceKeeper/IntensityCoach
haptic feedback. Syncs over BLE 4.0 to Swimmo iOS/Android app; optional Strava /
Under Armour / RunKeeper export.
- [SwimSwam Kickstarter coverage, 2015-04-15](https://swimswam.com/swimmo-watch-goes-live-on-kickstarter/)
- [itkey.media company profile, 2020-12-29](https://itkey.media/polish-swimmo-dived-deep-into-kickstarter/)
- [swimmo.com specs](https://www.swimmo.com/specs/)

## Why It's At-Risk / Partially Abandoned
- The Android app is **removed from Google Play**: Play Store search returns no Swimmo
  app (verified 2026-08-07). Package `com.swimmo.android` only survives on APK mirrors.
- swimmo.com and its shop are still online (verified 2026-08-07), but there is no
  evidence of ongoing development; updatestar's last-seen app version is 1.9.27
  (Jan 2025) while the mirror APK is 1.9.41. Company social/blog activity appears stale.
- Verdict: not confirmed dead — the store still sells — but the app delisting makes the
  ecosystem at-risk and justifies a local-control spec now.

## Local BLE Feasibility — GOOD
The app identifies the watch by advertised 128-bit service UUIDs and speaks plain GATT.
Pairing security is an **on-device password** written to a dedicated Authorization
characteristic (`AuthorizationCharacteristic.setPassword`) — no cloud round-trip.
Cloud is only used by the stock app for account login/social/leaderboard and
third-party export; the BLE protocol itself is fully local.

### GATT (from `com/swimmo/swimmo/BLEFunction/UUIDAdresses.java`)
Base UUID: `4D16xxxx-37B9-E213-60DE-C20A3692E96F`

| UUID (xxxx) | Role |
|------|------|
| 5000 | Config service |
| 5001 | Date/time |
| 5002 | Daily-watch settings |
| 5003 | Distance tracking |
| 5004 | Calories tracking |
| 5005 | Vibrations |
| 5006 | Factory reset |
| 5100 | Workouts service (advertised; used as scan filter) |
| 5101 | Workout types |
| 5102 | Workouts data |
| 5200 / 5201 | Authorization service / characteristic (device password) |
| 5400 / 5403 | Shutdown service / characteristic |
| 6000 / 6001 | Firmware-update service / command interface |
| std 0x180A | Device information (mfr/model/serial/HW/FW/SW rev) |
| std 0x180F / 0x2A19 | Battery |

Protocol handlers in `com/swimmo/swimmo/BLEFunction/` (`WorkoutCharacteristic`,
`ConfigCharacteristics`, `FirmwareUpdate`, CRC32 helper). Frame formats not yet mapped —
that is the remaining RE work.

## APK Provenance
- Package `com.swimmo.android`, version 1.9.41 (versionCode 204), ~9 MB bare APK
- Source: apkeep, apk-pure mirror, fetched 2026-08-07 (package id recovered from an
  archived swimmo.com/m/android/ page, 2019 Wayback capture)
- SHA-256: `6155c32e238c0b5b669d12e83b90b05db77e04d7d1b391703552d40a7ad94711`
- Native Java, unobfuscated (`com.swimmo.swimmo.*`)

## What Needs Cloud
Stock app gates on a Swimmo account (LoginActivity) for history/social features and
offers Strava/UA/RunKeeper OAuth export. None of that is in the BLE exchange; a local
client can pair (device password), pull workouts, set time/config, and trigger DFU
without any account.

## Open Questions
- Is the Swimmo cloud backend still up (account creation possible)? Untested.
- Exact workout frame layout and CRC usage (`CRC32Function`).
- iOS app still on the App Store? Not checked.
- Company solvency (Polish KRS) — unverified; site alive but quiet.
