# PUSH Band (PUSH Pro / Band 2.0) — Research Notes

## What it is
Forearm-worn 6-axis IMU (accel + gyro, 200 Hz) for velocity-based training (VBT) in
the weight room: bar velocity, power, rep counting streamed live to a phone over BLE.
Made by PUSH Inc (Toronto). Widely cited in sports-science literature (e.g. MDPI
2018 validity study: https://www.mdpi.com/2075-4663/6/4/140).

## Why it's abandoned
- **WHOOP acquired PUSH on 2021-09-02** and folded the tech into its strength
  coaching; PUSH hardware sales ended.
  (https://www.whoop.com/us/en/press-center/acquires-push-velocity-based-training-solution/)
- GymAware VBT buyers guide (2026-07-07): "these VBT devices are no longer
  available anymore." (https://gymaware.com/velocity-based-training-buyers-guide/)
- `trainwithpush.com` unreachable (verified 2026-08-07); app
  `com.pushstrength.pushflutter` 404s on Google Play (verified 2026-08-07).
- App changelog v7.18.0: "PUSH is now part of WHOOP! Please contact push@whoop.com."

## Local BLE feasibility — MODERATE
- Band→app link is pure BLE and real-time; the physics is computed on the phone
  (native `libAlgorithmInterface.so` ships in the APK), so no cloud is needed for
  the data path itself.
- BUT the app is coach-portal-centric: login + PUSH Portal sync everywhere. With
  the backend dead, the stock app likely can't be used at all. Value here is a
  clean-room BLE client.
- Flutter app (Dart AOT snapshot) — BLE constants are not in the DEX. Triage
  strings pass on `libapp.so` recovered one 128-bit UUID:
  `FDD39AD0-238F-46AF-ADB4-6C85480369C7` (likely the PUSH Band GATT service;
  role unconfirmed).
- APK also bundles `libModels.so` and Couchbase Lite (local DB + sync).

## Cloud dependence
- Account login, athlete roster, Portal session planning, history sync — cloud,
  presumed dead. Real-time velocity readout itself is local BLE + on-device DSP.

## APK provenance
- Package: `com.pushstrength.pushflutter` — bare APK, 71 MB, via apkeep
  `apk-pure`, 2026-08-07. Version not extractable from binary manifest at triage
  (soft112 lists 7.18.0 as last release, 2021-10-14).
- SHA-256: `ab9bd8b671cf9f38129afe18e04f6a844c077d2b904538458b07340fbac558a9`.
- Delisted from Play (404); fetchable from APKPure.

## Open questions
- Confirm `FDD39AD0-...` is the band service; enumerate characteristics (needs
  Flutter snapshot tooling or an nRF Connect scan of a live band).
- Streaming format of the 200 Hz IMU frames (notify packetization).
- Whether any pairing/bonding auth is required.
- Advertised name prefix ("PUSH"? — unverified).

## Difficulty note
Flutter AOT snapshots resist cheap static analysis; budget for dynamic capture
(HCI snoop with a live band) rather than more jadx time.
