# Beast Sensor — Research Notes

## What it is
Small magnetic IMU pod (Beast Technologies, Italy) that clips to a barbell or wrist
and streams motion data over BLE to the "Beast" app for velocity-based training:
bar speed, power, rep detection, "strength speed zones." Companion web portal for
history. Kickstarter-era device (~2014), sold at ~$289.

## Why it's abandoned
- VBT Coach buyers guide (2024-03-21) lists "Beast Sensor (IMU, **defunct**)"
  (https://vbtcoach.com/blog/velocity-based-training-devices-buyers-guide/).
- `thisisbeast.com` unreachable (verified 2026-08-07); app `com.thisisbeast.beast`
  404s on Google Play (verified 2026-08-07).
- App bundles Couchbase Lite sync — the cloud sync endpoint is presumed dead.

## Local BLE feasibility — STRONG
- Sensor→app is real-time local BLE; VBT math runs on the phone.
- jadx (app v2.3.7) recovered the full custom GATT family
  (`com/thisisbeast/beast/c/f/b/a.java`, obfuscated but UUIDs are literals):
  - Service A: `BEA5760D-503D-4920-B000-101E7306B000` with characteristics
    `...B000-101E7306B001` through `...B000-101E7306B006` (6 chars).
  - Service B: `BEA5760D-503D-4920-B001-101E7306B000` with characteristics
    `...B001-101E7306B001` .. `...B001-101E7306B003` (3 chars).
  - CCCD `00002902` used; at least 4 characteristics are notification-enabled in
    the discovered-service setup code; others are write targets.
- Kotlin app, obfuscated; semantic roles of each characteristic TBD.

## Cloud dependence
- Login/sync via Couchbase to Beast cloud (dead). Local BLE streaming itself has no
  cloud dependency; the stock app's account gate is the blocker → clean-room client.

## APK provenance
- Package: `com.thisisbeast.beast` — **version 2.3.7 (25001)**, bare APK, 21 MB,
  via apkeep `apk-pure`, 2026-08-07.
- SHA-256: `6a40470da1c501ef2a4c001ad0865f57dc82e170ed0a202a471aae3e7a92fb10`.
- Delisted from Play (404); fetchable from APKPure.

## Open questions
- Which characteristics carry the IMU stream vs commands (mapping is in obfuscated
  field assignments; a short jadx follow-up or one HCI snoop resolves it).
- Frame format (sample rate, packing, calibration).
- Advertised name prefix ("Beast"? — unverified).
- Whether pairing requires bonding/auth.
