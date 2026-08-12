# Generic BLE TPMS cap sensors (SYTPMS / TPMSII / ITPMS family) — Research Notes

## What it is
Unbranded/rebadged Chinese BLE tire-pressure cap sensors sold on AliExpress/Amazon
under dozens of listings (car, motorcycle, trike sets; ~$15-40). Companion apps:
**SYTPMS**, **TPMSII**, **ITPMS (K)** / **LYTPMS**, and a Michelin-branded TMS variant.
Sensors are passive BLE broadcasters — the phone never needs to connect.

## Why it counts as orphaned
Vendor-anonymous hardware with no manufacturer support channel, firmware updates, or
account system — orphaned by design. The apps are low-effort wrappers; if they vanish
from the stores the sensors are unreadable for normal users. This is the same
situation as other generic-device specs already in the repo (iTag, CoolLEDX).

## Prior art (advert format fully decoded)
- https://github.com/andi38/TPMS — full decode of the "BR"-name sensors: advert
  contains short name `BR`, 16-bit service UUID `0x27a5`, and 7-byte manufacturer
  payload `SSBBTTPPPPCCCC` = status / battery (1/10 V) / temperature (°C) /
  pressure (1/10 psi) / checksum. Example: `0303a527 03084252 08ff281d130105a376`.
  Status byte bitfield documented (alarm/rotating/standing/pressure-trend bits).
- https://github.com/ra6070/BLE-TPMS and
  https://www.instructables.com/BLE-Direct-Tire-Pressure-Monitoring-System-TPMS-Di/
- https://github.com/bkbilly/tpms_ble — Home Assistant integration (HACS),
  passive-only, covers four sensor/app families: Type A (TPMSII app), Type B
  (SYTPMS app), Type C (Michelin TMS), Type D (ITPMS K / LYTPMS apps).
- https://github.com/omadon/TPMS_BLE_BR — ESPHome variant.

## APK provenance
- **Package**: `com.bekubee.sytpms` ("SYTPMS")
- **Version**: 2.1 (14), XAPK (5.3 MB)
- **SHA-256**: `2177b5752d1bb2a4d4187fb7ca6c127799560aab261cd2e4ef24f8c6dd2a7ec2`
- **Source**: apkeep / apk-pure
- Static triage: **zero 128-bit GATT UUIDs and no GATT client code paths in dex
  strings** — consistent with pure passive-advert parsing (BLUETOOTH_SCAN +
  LeScanCallback only). Corroborates the community decode.

## Local feasibility
Fully confirmed by multiple independent implementations. ESP32/ESPHome or any
BLE scanner can decode adverts; no pairing, no app, no cloud. Sensors transmit on
pressure change and every couple of minutes while pressurized; more often when
rotating (~4-8 km/h+).

## Open questions
- The four app families imply at least 3-4 advert layouts; only Type B ("BR") is
  byte-level documented above — bkbilly/tpms_ble source covers the rest.
- Sensor config (ID/wheel position) is fixed at factory; no write path known or needed.

## Safety
TPMS monitoring is safety-adjacent but read-only. MEDIUM.
