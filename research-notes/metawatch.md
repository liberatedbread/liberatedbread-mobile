# MetaWatch — Research Notes

Developer-friendly smartwatch (Fossil spin-off) whose firmware, Android app and
protocol spec were all published as open source. Company quietly defunct; the
watches remain fully drivable over plain SPP — even from an Arduino.

## Device / Company Status
- **Products**: MetaWatch developer watches WDS111/WDS112 (digital 96x96) and
  analog line (2009-2011, "Fossil/Metawatch" era), retail Strata, Frame and
  META M1 (2012-2014). TI MSP430 + CC2560 dual-mode Bluetooth (SPP + BLE).
- **Company**: spun out of Fossil in 2011 ([SYNNEX press release, 2014](https://ir.synnex.com/news/press-release-details/2014/New-Age-Electronics-Brings-Meta-Watch-Premium-META-M1-Smartwatches-to-the-Retail-Channel/default.aspx)).
  No dated obituary found — rated *defunct* on evidence: GitHub org silent since
  2015-03-23 (last push to MetaWatch-Gen2), metawatch.org parked (verified
  2026-08-07), Android app gone from Play and APK mirrors.

## Local Feasibility: CONFIRMED (source-available, not just RE)
- **Transport**: Bluetooth Classic SPP (+ BLE on CC2560, unused by most tooling).
- **Official protocol spec**: "MetaWatch Firmware Design Guide" PDF publicly
  documents the SPP message protocol — message type byte, options, little-endian
  length; modes (idle/application/notification); display-buffer writes, buttons,
  vibrate, RTC ([cdn-reichelt.de mirror](https://cdn-reichelt.de/documents/datenblatt/A300/METAWATCH_DESIGN_GUIDE.pdf)).
- **Open-source everything** (github.com/MetaWatchOpenProjects):
  - `MetaWatch-Gen2` — complete watch firmware incl. Bluetooth stack + remote
    protocol handler (last push 2015-03-23).
  - `MWM-for-Android-Gen1` (and Gen2 sibling repo) — the companion app source.
- **Third-party clients**: travisgoodspeed/PyMetaWatch (Python, PC over SPP);
  ka010/MWKit (macOS/iOS); SparkFun tutorial drives the watch from an Arduino
  via a BlueSMiRF SPP module
  ([learn.sparkfun.com](https://learn.sparkfun.com/tutorials/metawatch-teardown-and-arduino-hookup/all)) —
  direct proof that no phone, app, account or cloud is needed.

## APK Provenance
- **Package**: `org.metawatch.manager` (MetaWatch Manager)
- **Fetchable: NO** — apkeep/APKPure lists zero versions; delisted from Play.
  Mitigation: full app source is on GitHub (build from source), and the protocol
  spec + PyMetaWatch make the app unnecessary for local control.

## Open Questions
- BLE side of the CC2560 firmware is present in source but community tooling all
  targets SPP — SPP is the documented path; leave BLE unexplored.
- Precise wind-down date of MetaWatch Ltd. (hypothesis: 2015; evidence above).

## Sources
- github.com/MetaWatchOpenProjects/MetaWatch-Gen2 (firmware, open source)
- github.com/MetaWatchOpenProjects/MWM-for-Android-Gen1 (app source)
- cdn-reichelt.de MetaWatch Firmware Design Guide PDF (official protocol spec)
- github.com/travisgoodspeed/PyMetaWatch
- learn.sparkfun.com/tutorials/metawatch-teardown-and-arduino-hookup (SPP from Arduino)
- ir.synnex.com 2014 press release (Fossil spin-out history)
