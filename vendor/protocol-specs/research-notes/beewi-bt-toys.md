# BeeWi Bluetooth Classic RC Toys — Research Notes

## What it is
BeeWi (Marseille) Bluetooth **Classic SPP** smartphone-controlled toys, ~2012–2015:
- **BBZ301 / BBZ302 "Sting Bee"** Bluetooth combat mini helicopter (app: "BeeWi HeliPad", `com.beewi.helipad`).
- **BBZ201 / BBZ251 Mini Cooper S** Bluetooth RC car (app: "BeeWi Control Pad").
- Wi-Fi camera buggy and other "Control Pad" vehicles (Wi-Fi models out of scope).

## Why it is abandoned
- BeeWi was created in 2009 as a subsidiary of **Avenir Telecom** (Marseille). Avenir Telecom's assets were sold off via the Marseille commercial court; **HBF Group acquired BeeWi** and folded the brand into its **Otio** smart-home brand ([VIPress](https://vipress.net/toulousain-hbf-acquiert-societe-dobjets-connectes-beewi/); Otio's own brand history dates the Otio/BeeWi brand fusion to **2016**: [otio.com/la-marque-otio](https://www.otio.com/la-marque-otio)).
- The toy line was dropped in the merger (Otio kept only smart-home products). The apps are unmaintained: HeliPad's last update was ~2014–2016 per APK mirrors; it is no longer on Google Play (apkeep pulls it only from APKPure).
- No cloud component at all — the toys are plain SPP serial peers; control is fully local.

## Local Bluetooth Classic feasibility: EXCELLENT (confirmed by static analysis)
SPP UUID `00001101-0000-1000-8000-00805F9B34FB` confirmed in `com.beewi.helipad` v2.0 DEX (`com/beewi/helipad/ConnectionHelper.java:26`, `createRfcommSocketToServiceRecord`).

**Helicopter protocol (recovered from jadx, `App.java getBytesCommand`)**: the command is a **14-character ASCII hex string** sent verbatim over the SPP stream:

```
"0x" + O + GG + YY + XX + TT + FF     (e.g. idle: "0x14000000040F")
  O  1 hex digit  joystick quadrant/orientation (signs of x,y)
  GG 2 hex digits throttle (gaz), 0x00-0xFF
  YY 2 hex digits pitch magnitude  (|y|*17, clamped 0xFF)
  XX 2 hex digits roll magnitude   (|x|*17, clamped 0xFF)
  TT 2 hex digits trim (|trim|*8)
  FF 2 hex digits fire/shield: idle "01"/"0F"; firing "<team>1" (standard) / "<team>F" (expert mode)
```
- App streams the command continuously (sent 3x at connect, then on state change).
- Session end command: literal `"0x14000000040F"` (`getBytesCommandEnd`).
- Device replies/status frames: app reads an input stream (`buffInputStream`) — not fully mapped; flight works write-only in practice.

**Mini Cooper (BBZ201)**: separate "BeeWi Control Pad" app (package id not recovered; `com.beewi.controlpad`/`com.beewi.minicar` NOT on APKPure). Community RE exists: [jimmckeeth/BeeMiniCtrl](https://github.com/jimmckeeth/BeeMiniCtrl) — Delphi Android client for the BBZ201, "may work with other BeeWi Bluetooth remote control vehicles". Protocol likely same ASCII-hex family (unverified).

## APK provenance
- **Fetched**: `com.beewi.helipad` v2.0 (versionCode 4), apkeep `-d apk-pure`, SHA-256 `1ae19aab72dedf2817f7a0848be46c6f83256f4165f8fcd1abda3d8615a7b3cf`. jadx triage complete.
- **Not fetchable**: BeeWi Control Pad (car app) — package id unknown; archive search needed.

## Open questions
- Exact orientation-nibble encoding (quadrant map in `App.getOrientationValue`).
- Car protocol: confirm it matches the helicopter's ASCII-hex format (BeeMiniCtrl source).
- Whether the heli sends any telemetry worth parsing.

## Verdict
Document. Company/brand dead for toys, zero cloud, SPP confirmed, and the flight protocol is already fully recovered as a trivially-implementable ASCII command. Difficulty: trivial for the helicopter; easy for the car once Control Pad APK or BeeMiniCtrl constants are mined.
