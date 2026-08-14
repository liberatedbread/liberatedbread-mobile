# GAPS.md

Last updated: 2026-08-12

## Remaining Gaps: 1

| Target | Status |
|--------|--------|
| **ifreqtech-speaker-mic** | No companion APK exists — BT Classic hardware bridge (HFP + likely SPP). Requires HCI snoop on physical device. RE blocked until hardware in hand. |

## Resolved: 27 of 27 original targets

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
| led-space | → led-space.yaml (third app on the LOY SPACE / popled.cn platform; Wi-Fi AP/UDP 9090 path documented from com.yj.led static analysis) |

## Resolved: m6-fitness-band (was "Uncertain")

RESOLVED 2026-07-31: the Veryfit 2.0 (`com.veryfit.multi`) app-to-device match was
positively REFUTED by the M6's own stock firmware dump (rbaron/m6-reveng) — no 0AF0
UUID exists anywhere in the 512 kB flash. The M6 is an LT716-platform device speaking
the FitPro protocol (NUS + 0xCD-framed commands + Telink OTA, advertised name "M6",
companion app `xfkj.fitpro`). `m6-fitness-band.yaml` was re-targeted accordingly and
keeps the Veryfit analysis only as a clearly-labeled mis-attribution note. See
`research/m6-fitness-band/CONFIRMATION.md` §C.

## Validation: 92/92 passing (91 device specs + 1 example)
