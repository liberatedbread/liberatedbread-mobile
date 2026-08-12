# Quicklynks BM2 / BM6 12V Battery Monitor — Research Notes

## What it is
Thumb-sized BLE monitor that bolts onto a 12V battery terminal: real-time voltage,
cranking test, charging/alternator test, ~35-day history. Sold under many brands:
QUICKLYNKS BM2/BM6, ANCEL BM200, Sealey BT2020, and unbranded clones.

## Abandonment status — honest assessment: LOW risk
Vendor is **active**: the "BM2" app (`com.dc.battery.monitor2`, ICS Technology) is
still on Google Play, updated 2025-10-30 ("Compatible with Android 15"). The
device needs **no account and no cloud** — everything is local BLE. Included
because the category brief names Quicklynks explicitly and the protocol is fully
public; this is a liberation-complete reference, not an at-risk rescue.
Play listing: https://play.google.com/store/apps/details?id=com.dc.battery.monitor2

## Prior art (protocol fully RE'd)
- https://github.com/KrystianD/bm2-battery-monitor — Python client + ESPHome
  template + MQTT example; full RE writeup. App keywords: "com.dc.battery.monitor2,
  ICS Technology".
- https://github.com/andystewart999/ha_bm2monitor — Home Assistant custom integration.
- BM6/ANCEL BM200/Sealey BT2020: https://www.tarball.ca/posts/reverse-engineering-the-bm6-ble-battery-monitor/
  (referenced from https://github.com/fl4p/batmon-ha/issues/160) — encrypted
  adverts on BM6, since decoded.
- https://community.home-assistant.io/t/bm6-battery-monitor-esphome/806239

## APK provenance
- **Package**: `com.dc.battery.monitor2` ("BM2 - Battery Monitor BLE")
- **Version**: 3.8.0 (111)
- **SHA-256**: `7fcdf2a2e2416f3f0655c8c704f97e1b2e37c6d8951a5bf84c82c93da1bbc94d`
- **Source**: apkeep / apk-pure (bare APK, 4.7 MB)

## BLE findings (static, strings over dex)
- Service `0000fff0`, characteristics `0000fff3` (write) / `0000fff4` (notify) —
  matches KrystianD's published RE.
- `0000fee0/fee1` — second channel (likely config/history on some firmware).
- TI OAD service `f000ffc0-0451-4000-b000-000000000000` (+ffc1/ffc2) → CC254x SoC.
- BM6 variant uses rotating/encrypted manufacturer adverts (see tarball.ca writeup);
  BM2 uses plain GATT request/response.

## Local feasibility
Confirmed by multiple independent implementations: connect GATT, enable notify on
fff4, write request frames to fff3, parse voltage replies; history download supported.
No pairing, no account, no cloud.

## Open questions
- Fee0/fee1 channel role (not needed for basic monitoring).
- BM6 clone coverage: which hardware revisions encrypt adverts vs plain GATT.

## Safety
Read-only battery telemetry on a 12V system; cranking/charging tests are passive
measurement. LOW.
