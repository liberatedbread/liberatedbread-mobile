# Omron Avail (PM601) — Wireless Dual-Channel TENS — Research Notes

Date researched: 2026-08-04.

## What it is
Omron Avail (PM601, launched Jan 2018) is a wireless, dual-channel TENS +
microcurrent device. Two soft contoured pads hold the stim pods; **the pods have
no meaningful onboard controls** — mode selection, 20 intensity levels, and
session control all happen in the "OMRON TENS" smartphone app over BLE
([PT Products Online, 2019-08-28](https://ptproductsonline.com/exercise-rehab/pilates/omron-avail-wireless-tens-device-aims-provide-drug-free-pain-relief/);
[PM601 instruction manual](https://omronhealthcare.com/storage/pdfs/avail-wireless-tens-unit-pm601-im-en.pdf): "Download and install the free 'Omron TENS' app").

## Why it is abandoned / at-risk
- Product is **discontinued**: Omron no longer lists or sells the Avail, and
  owners report Omron told them directly it was discontinued and consumable pads
  were dropped ([Best Buy owner review, 2022](https://www.bestbuy.com/site/reviews/omron-avail-wireless-dual-channel-tens-kit-white/6341874)).
- The Android app has vanished: not on Google Play mirrors (APKPure returns no
  package), not on Aptoide. iOS app (`id1225437437`, v1.4.1 per a 2024 software
  directory entry) may still be up, but the Android APK is the RE target and is
  currently **unrecovered**.
- Omron Healthcare is alive — this is a dropped product line, not a dead company.

## Local BLE feasibility: HIGH in principle (hypothesis — no APK yet)
- All device control is BLE; no account or cloud dependency was ever documented
  (app pairs directly per the manual). Device is a brick without an app.
- No known community RE (no GitHub driver / HA integration found).

## APK status: NOT acquired (2026-08-04)
- Package id unknown — Google Play listing is gone; Wayback CDX query timed out
  (retry: search `web.archive.org` for `play.google.com/store/apps/details?id=*omron*tens*`).
- Checked: apkeep/apk-pure (empty for all guessed ids: `com.omronhealthcare.omrontens`,
  `com.omron.tens`, `com.omronhealthcare.avail`, `jp.co.omron.tens`, ...), Aptoide
  search API (no hit).
- Recovery options: extract from a phone that still has it installed; find an
  archived Play page to get the package id, then re-try mirrors; or ask owner
  communities (the Best Buy review thread shows an active owner base).

## Expected protocol shape (to verify once APK lands)
- Likely a custom GATT service with command + notify characteristics; dual
  channel → per-channel intensity/mode values. Firmware is the safety gate.

## Open questions
1. Android package id and any surviving APK copy.
2. BLE pairing/bonding model; whether pods accept connections without app auth.
3. Electrode pad supply is the other orphaning axis (proprietary pads).

## Safety
safety_class MEDIUM: active electrical stimulator. Keep to app-level
mode/intensity commands; firmware enforces stimulation limits.
