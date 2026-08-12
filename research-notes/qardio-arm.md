# QardioArm (A100) Smart Blood Pressure Monitor — Research Notes

## What it is
QardioArm is a Bluetooth LE upper-arm blood pressure monitor from Qardio, Inc.
(San Francisco). Sibling devices on the same app/platform: QardioBase / QardioBase 2
smart scale and QardioCore ECG patch.

## Why it's abandoned (dated sources)
- Qardio, Inc. went bankrupt; the official app vanished from the Apple App Store —
  reported 2024-09-23 ([Apple Support Community](https://discussions.apple.com/thread/255768352)).
- Qardio cloud servers went down 2025-04-29 and did not return, breaking the official
  app's sync ([Apple Support Community](https://discussions.apple.com/thread/256006237)).
- Long-form post-mortem: [technodabbler.com, 2026-05-19](https://www.technodabbler.com/what-happened-to-qardio-when-connected-health-devices-stop-working/).
- Android app `com.getqardio.android` returns 404 on Google Play (checked 2026-08-03).

## Local BLE feasibility — CONFIRMED, with working open-source clients
- **LibreArm** (iOS, GPL, [github.com/ptylr/LibreArm](https://github.com/ptylr/LibreArm),
  live on the App Store) connects directly to the cuff over BLE — "no Qardio cloud or
  accounts required". Author's writeup: [ptylr.com, 2025-09-28](https://ptylr.com/posts/2025-09-28-librearm-breathing-new-life-into-qardioarm-devices).
- **LibreArm_Android** port: [github.com/agreenbhm/LibreArm_Android](https://github.com/agreenbhm/LibreArm_Android).
- Protocol (from LibreArm `Core/BPClient.swift`, cross-confirmed by APK strings):
  - Standard Blood Pressure service `0x1810`, measurement char `0x2A35` (SIG-standard
    Blood Pressure Measurement format: systolic/diastolic/MAP as IEEE-11073 SFLOAT, pulse).
  - Vendor control characteristic `583CB5B3-875D-40ED-9098-C39EB0C1983D` (inside the
    0x1810 service): write `F1 01` = start measurement, `F1 02` = cancel.
  - Battery: standard `0x180F` / `0x2A19`.
  - Pairing/bonding is used; on pairing ATT errors (codes 0x05/0x08/0x0C/0x0F) the cuff
    needs a factory reset via the LED pinhole, then forget-and-reconnect.
  - Cuff emits partial readings while inflating; only save when sys+dia present.
- No cloud, account, or MITM needed at any stage — fully local. This is the gold-standard
  rescue scenario.

## APK provenance
- **Package**: `com.getqardio.android` (delisted from Play; still on APKPure)
- **Source**: apkeep `-d apk-pure`, downloaded 2026-08-03
- **Latest version listed**: 2.5.1 (1.32.2 → 2.5.1 available)
- **APK SHA-256**: `50681c026b9ef2987b14a82307804b03e6e9b31bf319d58a4ce40197bf5e5b95` (~83 MB)
- DEX strings confirm: BLP service 0x1810, char 0x2A35, vendor char `583CB5B3-…`,
  Nordic legacy DFU UUIDs (`0000152x-1212-efde-1523-785feabcd123`, `8EC9…` secure-DFU
  family partially), plus QardioBase device classes (`BeforeConnecting(qardioBaseDevice=…`).

## What needs cloud (nothing for control)
- Official app synced history to Qardio cloud — dead; LibreArm writes to Apple Health /
  Google Fit locally instead.
- Firmware updates (Nordic DFU) presumably came via app bundles — now frozen; not required
  for operation.

## Safety
- safety_class: MEDIUM. Blood pressure readings inform medication decisions; device is a
  cleared medical monitor, but any third-party client must not alter readings or give
  diagnostic advice (LibreArm explicitly positioned itself as wellness logging to satisfy
  App Store review).

## Open questions
- QardioBase 2 scale and QardioCore ECG share the app; QardioBase BLE protocol is in the
  APK but NOT yet community-RE'd (openScale has no QardioBase support). Separate RE target.
- Advertising name prefix for QardioArm ("QardioArm"?) — grab from a live scan or LibreArm scan filter.
- Nordic DFU service variant on the cuff (legacy vs secure) for archival firmware work.
