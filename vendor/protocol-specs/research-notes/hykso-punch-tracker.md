# Hykso Punch Trackers — Research Notes

## What it is
Hykso: a pair of wrist/hand-wrap BLE IMU trackers (2016–2018, ~$150) that count and
classify punches (jab, cross, hook, uppercut), punch speed and volume for boxing/kickboxing,
streaming live to the Hykso app.

## Why it is abandoned
- Hykso Inc. pivoted to the FightCamp connected-gym product and **dropped support for the
  original punch trackers**: "Hykso itself has already dropped further support for their
  trackers and now rebranding everything under the new FightCamp label"
  ([ExpertBoxing, 2021](https://expertboxing.com/boxing-punch-trackers-review)).
- The Hykso app is gone from Google Play (mirrors only; final version 1.02.03).
- Note: FightCamp itself is still operating (shop/support live as of 2025) — this note
  covers only the orphaned first-gen Hykso hardware, not FightCamp trackers.

## Local BLE feasibility
- Trackers stream IMU/punch events over BLE; punch counting/velocity runs between
  tracker firmware and phone — no cloud in the data path for live stats.
- UUID literals recovered from `com.hykso.hyksofit` dex (v1.02.03):
  - Custom family `ca281069`–`ca281079-5470-4e34-94dd-caf160200b29` plus `ca280069-...`
    (11+ characteristics; `ca281079` is likely the service, rest are characteristics —
    role mapping TBD)
  - Standard DIS chars `2a23`–`2a29`, battery `180f`, CCCD `2902`
- BLE entry point class: `HyksoBleActivity`. App is small (~9 MB base apk) — cheap jadx target.

## APK details (apkeep, apk-pure)
- Package: `com.hykso.hyksofit`, version 1.02.03 (final), XAPK
- SHA-256 (xapk): `100458c78d6ccee25825d1bb1b6c6b07e816e34801fd84dafeb92fc82f058715`

## Open questions
- Does the app require a Hykso account login before tracking? (Server dead → stock app
  may be unusable; local client needed.)
- Frame format for punch events vs raw IMU stream — jadx `com.hykso.*` BLE classes.
- Whether velocity computation needs per-tracker calibration data from the dead server.
