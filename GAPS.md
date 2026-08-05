# GAPS.md

Last updated: 2026-07-30

## Remaining Gaps: 2

| Target | Status |
|--------|--------|
| **ifreqtech-speaker-mic** | No companion APK exists — BT Classic hardware bridge (HFP + likely SPP). Requires HCI snoop on physical device. RE blocked until hardware in hand. |
| **led-space** | Target researched (`targets/led-space.md`) but no spec written yet. |

## Resolved: 26 of 27 original targets

| Target | Resolution |
|--------|-----------|
| switchbot-ble | YAML written |
| govee-h5075, h5080, h6001 | 3 YAMLs written |
| gerbing-thermogauge | 10 UUIDs from IL disassembly, YAML written |
| elk-bledom | YAML written |
| ibbq-meat-thermo | YAML written |
| itag-ble-tracker | YAML written |
| xiaomi-miflora | YAML written |
| xiaomi-lywsd03mmc | YAML written |
| xiaomi-mi-scale | YAML written |
| niimbot-d110 | YAML written |
| cat-printer | YAML written |
| fichero-d11 | YAML written |
| shining-glasses, shining-mask | 2 YAMLs written |
| spider-farmer-ggs | YAML written |
| hotwired-heated-gear | Full frame format (AA/CC), YAML written |
| etekcity-smart-scale | YAML written |
| iledcolor-led-panel | YAML written |
| ble-pulse-oximeter | YAML written |
| divoom-pixoo | 666-line spec, 17 pixel encodings, YAML written |
| bmw-motorcycle-motoscan | → obd2-bluetooth-adapter.yaml (OBD-II/CAN) |
| motorcycle-ground-effect-lighting | → split: proglow ✅, seeblue ✅, opt7=elk-bledom ✅, xkglow ✅ |
| roku-local-remote | → roku-ecp.yaml (protocol fully documented) |

## Uncertain: m6-fitness-band

`com.veryfit.multi` (Veryfit 2.0, 7.5MB) downloaded. May or may not be the correct
companion app. A spec (`m6-fitness-band.yaml`) has since been written from it, but
the app-to-device match is unconfirmed, so treat the spec as provisional.

## Validation: 71/71 passing (70 device specs + 1 example)
