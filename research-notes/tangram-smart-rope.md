# Tangram Smart Rope — Research Notes

## What it is
Tangram Factory Smart Rope (LED / Pure / Rookie models, 2015+): a BLE jump rope. The LED
model shows jump count mid-air via persistence-of-vision LEDs in the rope; all models
count jumps/calories and sync to the SmartRope app. Company site still live:
[tangramfactory.com](https://tangramfactory.com/smartrope/en/).

## Why it is at-risk (not fully dead — rated honestly)
- Company appears alive ([VCBeat lists "in operation"](https://www.vcbeathealth.com/entity/188927);
  product pages live 2026), but the software shows rot: App Store reviews report the
  SmartGYM/SmartRope app **refusing to start without a server connection** ("Unable to
  start SMART GYM - SMART GYM requires a network connection...") — a cloud kill-switch
  pattern that bricks the rope's app the day the server dies
  ([appstor.io reviews](https://smart-gym-pro.appstor.io/)).
- Android SmartRope app frozen at v1.4.92; not clearly maintained.
- Verdict: cloud-at-risk, and the stock app's network requirement makes local BLE
  liberation genuinely useful rather than hypothetical.

## Local BLE feasibility — good
- Jump counting is done in the handle (hall/motion sensors); rope streams counts over BLE.
- UUID literals recovered from `com.tangramfactory.smartrope` dex (v1.4.92):
  - **Nordic UART**: service `6e400001-b5a3-f393-e0a9-e50e24dcca9e`, RX `6e400002`,
    TX `6e400003` — simple serial bridge, easiest possible RE target
  - Nordic legacy DFU `00001530-1212-efde-1523-785feabcd123` + Secure DFU `fe59`
- App strings show clean protocol classes (`SmartRopeInterface`, `SmartropeRecord`).

## APK details (apkeep, apk-pure)
- Package: `com.tangramfactory.smartrope`, version 1.4.92 (final), XAPK
- SHA-256 (xapk): `c8f4983692bf08d2668c8415281486c167908adb91d0d04788dac4806e909e42`

## Open questions
- Command/event frame format over the UART (jump count, LED config, battery) — jadx
  `SmartRopeInterface` or an HCI snoop; likely trivial.
- Does the Android app v1.4.92 also enforce network-at-startup, or is that iOS-only?
- Per-model differences (LED model LED-pattern config commands vs Rookie count-only).
