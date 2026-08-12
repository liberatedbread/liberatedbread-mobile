# Atlas Wearables Wristband — Research Notes

## What it is
Wrist-worn strength-training tracker (Atlas Wearables, Austin TX; Kickstarter 2014,
Wristband 2 in 2016): 3-axis IMU + optical HR, on-device touchscreen, automatic
exercise recognition and rep counting. Dual-MCU design (STM32 + nRF51822 — the app
has distinct `expectedSTMVersion` / `expectedNRFVersion` firmware checks and an
`awFirmwareUpdate` path). Reviews: PCMag 2016-02-12, TechCrunch 2016-07-06.

## Why it's abandoned
- Company went quiet after ~2017; `atlaswearables.com` unreachable (verified
  2026-08-07); apps `com.atlaswearables.ionic` (phone) and
  `com.atlaswearables.ionic.androidwear` 404 on Google Play (verified 2026-08-07).
- FitnessSyncer kept an Atlas cloud-integration FAQ up
  (https://www.fitnesssyncer.com/support/atlas-wearables) — the Atlas cloud API it
  fronted is presumed dead with the domain.

## Local BLE feasibility — STRONG, with a big head start
- Band works standalone for basic tracking; app is needed for exercise library,
  learning mode (`awSendLearn`), sync, and firmware.
- The app speaks the **open-source Firefly Ice protocol** (Firefly Design):
  `AWPlugin.java` instantiates `FDFireflyIceManager` / `FDFireflyIceChannelBLE`
  with service UUID `577FB8B4-553E-4807-9779-8647481D49B3`. The Firefly Ice BLE
  layer is published (github.com/fireflydesign), so framing, reliability, and
  characteristic layout can be read from source instead of reverse-engineered.
- App is Cordova/Ionic — all device logic callable from JS in `assets/www`
  (`plugins/com.atlaswearables.cordova.AWPlugin/www/AWPlugin.js`): getDeviceInfo,
  setPreferences, fullSync, fastSync, sendLearn, firmwareUpdate, restartDevice.
- A second UUID `a327cf3c-f033-4a54-8b7f-03c56ba3203f` appears in the JS (role TBD).

## Cloud dependence
- Account/workout-history sync to Atlas cloud (dead). Exercise DB and ML models
  appear bundled/on-device; local BLE session does not inherently need the cloud.

## APK provenance
- Package: `com.atlaswearables.ionic` — **version 2.3.16 (203162)**, bare APK,
  32 MB, via apkeep `apk-pure`, 2026-08-07.
- SHA-256: `5ea64eab40ef8d2e2d99392cb3b2e70500d60a1fc1adaf7ebd51f0d2b9c56419`.
- Wear companion `com.atlaswearables.ionic.androidwear` also known; not fetched
  (missed on apk-pure).
- Delisted from Play (404); phone app fetchable from APKPure.

## Open questions
- Map Atlas-specific RPCs (learn mode, exercise DB download, HR streaming) onto the
  Firefly Ice command set.
- Whether exercise-recognition models live on the band (STM32) or phone.
- Advertised name format: app parses `deviceNameSegments[1]` as device UUID — name
  prefix pattern TBD.
- Firmware update source (bundled in APK assets vs dead server).
