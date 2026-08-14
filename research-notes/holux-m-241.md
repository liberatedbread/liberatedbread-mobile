# Holux M-241 GPS Logger — Research Notes

Category: Bluetooth Classic (SPP) GPS data logger. Also covers sibling receivers M-1000/M-1000C/M-1200, GPSlim 236/240 (live-position-only, plain NMEA-over-SPP).

## Company / Cloud Status — DEAD
- Holux Technology (長天科技, Taiwan) announced mass layoffs 2019-07-16 and went bankrupt; official website and store taken offline ([eeworld, 2019-07-18](https://en.eeworld.com.cn/news/qrs/eic468435.html), [gpsbabel issue #349](https://github.com/GPSBabel/gpsbabel/issues/349), [holux.info FAQ](https://holux.info/faq/) — fan-run archive of the dead vendor site).
- No cloud dependency in the device itself, but the Windows-only config app **ezTour** required online registration/license after the site died — Chinese-language revival writeups report ezTour can connect but cannot export tracks post-shutdown ([cnblogs.com M-241 Plus revival, 2021](https://www.cnblogs.com/qq812256/p/14822643.html)). Open-source tools replace it fully.
- Community mirror of manuals/firmware/FAQ: holux.info (fan-maintained, still online as of 2026-08).

## Companion App
- **No Android or iOS app ever existed.** Config was Windows PC software: ezTour (M-241) / ezTour Plus (M-241 Plus), now abandonware with a dead license server.
- Open-source replacements: **BT747** (bt747.org, Java, still maintained — v2.3.1 2021) and **gpsbabel** (`m241`, `m241-bin` formats) cover all config + log-download functionality.

## Transport — Bluetooth Classic SPP
- Profile: Serial Port Profile (SPP), Bluetooth 1.2/2.0. UUID: standard SPP `00001101-0000-1000-8000-00805f9b34fb`.
- Pairing PIN: **0000** (confirmed by [holux.info FAQ](https://holux.info/faq/) and AOKA camera-GPS compatibility lists pairing "0000" with Holux M-241/M-1000/M-1200/GPSlim 236/240).
- Host-side baud over `rfcomm` is emulated; device streams NMEA at its configured rate (38400 commonly reported for the M-241).

## Protocol
- **Live position**: NMEA 0183 sentences (GGA/RMC/GSA/GSV) streamed over SPP — works directly with `gpsd` (`gpsd -N rfcomm0:` after `rfcomm bind`) or any NMEA parser. Zero vendor code needed.
- **Log download / config**: MediaTek MTK chipset with a **Holux-specific variant** of the MTK binary protocol (gpsbabel documents it as an "incompatible variation" — hence dedicated `m241`/`m241-bin` formats instead of `mtk`). Config commands are PMTK-style `$PMTK...*CS\r\n` packets over the same SPP link; log memory is dumped as binary blocks and decoded per gpsbabel `m241-bin`.
- Bidirectional over SPP: BT747 can configure logging interval/criteria and download/erase logs over Bluetooth (USB also works on M-241).
- ~130,000 trackpoints; GPSport 245 (sibling, display model) ~200k, auto-detected by gpsbabel `m241-bin`.

## Known Issues
- **GPS week-number rollover**: M-241 mis-dates logs after rollovers (2019); gpsbabel issue #349 tracks it; BT747 adds +1024 weeks for pre-2009 dates (bt747.org news).
- Rechargeable batteries in ~15-year-old units are commonly dead; AA-powered M-241 ages better than sealed siblings.

## Local Feasibility — CONFIRMED
Live position: generic NMEA-over-SPP, gpsd out of the box. Log/config: mature open-source tooling (BT747, gpsbabel). No cloud, no account, no intercept needed.

## Open Questions
- Exact Holux-vs-generic MTK binary frame deltas (documented in gpsbabel `m241-bin` source, not separately spec'd).
- ezTour's broken post-shutdown features (map download) — irrelevant given open tooling.

## Sources
- [holux.info FAQ](https://holux.info/faq/) / [holux.info M-241](https://holux.info/m-241/) (community archive of vendor docs)
- [gpsbabel m241-bin format doc](https://www.gpsbabel.org/htmldoc-development/fmt_m241-bin.html)
- [gpsbabel mtk format doc](https://www.gpsbabel.org/htmldoc-development/fmt_mtk.html)
- [M-241 user manual PDF (rigacci.org mirror)](https://www.rigacci.org/wiki/lib/exe/fetch.php/doc/appunti/hardware/gps/holux_m241_gps_logger_user_manual.pdf)
- [bt747.org](http://www.bt747.org/)
