# Transystem i-Blue 747 GPS Logger — Research Notes

Category: Bluetooth Classic (SPP) GPS data logger. Covers i-Blue 747, 747A+, 747Pro/747Pro S, and siblings i-Blue 737/757/821 (receivers or MTK loggers).

## Company / Cloud Status — EFFECTIVELY DEAD FOR THIS LINE
- Transystem Inc. (Taiwan) made the i-Blue line; the consumer GPS-logger business is long discontinued — resellers list i-Blue 747 as "discontinued by the manufacturer" ([gpswebshop](https://gpswebshop.com/products/i-blue-747-bluetooth-gps-receiver-with-16mb-push-to-log-data-logger-auto-on-off-32-channels-waas-bluetooth-gps-usb-gps-google-integration)) and the vendor's old product pages are gone. (Transystem's corporate site was unreachable at research time, 2026-08-03; the brand survives only in second-hand markets.)
- No cloud dependency in the device; the bundled Windows config utility is abandonware and fully replaced by open tools.

## Companion App
- **No Android or iOS app ever existed.** Configuration was a Windows utility shipping on CD.
- Open-source replacements (mature):
  - **BT747** (bt747.org, Java, desktop + J2ME/Palm/WinCE; last release 2.3.1, 2021) — the reference implementation of the MTK logger protocol.
  - **gpsbabel** `mtk` format — i-Blue 747, 747A+, 821 listed as **confirmed working** ([gpsbabel mtk doc](https://www.gpsbabel.org/htmldoc-development/fmt_mtk.html)).
  - **MTKBabel** (Perl, rigacci.org) — minimal CLI downloader for i-Blue 747 and other MTK loggers ([rigacci wiki](https://www.rigacci.org/wiki/doku.php/doc/appunti/hardware/gps_logger_i_blue_747)).

## Transport — Bluetooth Classic SPP
- SPP profile, Bluetooth 2.0, standard UUID `00001101-0000-1000-8000-00805f9b34fb`.
- Pairing PIN: **0000** (standard for the line, per era reviews/manuals).
- USB also present (Silicon Labs CP210x bridge on the 747A+, per gpsbabel) — the most robust log-download path.

## Protocol
- **Live position**: NMEA 0183 over SPP — feed `rfcomm0:` to gpsd; no vendor code.
- **Log download / config**: MediaTek MTK chipset (MT3318/MT3329 family), generic MTK binary protocol — PMTK text commands for config (`$PMTK...*CS\r\n`), binary block dump for the 16 MB flash log (~100k–125k waypoints). Fully documented by gpsbabel `mtk`/`mtk-bin` and BT747 source.
- gpsbabel caveat: some MTK loggers can't receive commands over Bluetooth (send-only); BT747 historically configures the 747 over SPP, but USB is guaranteed bidirectional.

## Known Issues
- GPS week-number rollover: Transystem GLOG 760 mis-dates logs (BT747 adds +1024 weeks for pre-2009 dates, v2.2.1+ — [bt747.org](http://www.bt747.org/)); same-era 747 firmware is suspect.

## Local Feasibility — CONFIRMED
Generic MTK protocol with multiple independent open implementations. Works entirely locally today; no cloud, no account, no intercept.

## Open Questions
- Exact per-revision differences (747 vs 747A+ vs 747Pro S flash size/record format) — handled in practice by gpsbabel/BT747 device tables.
- Whether every firmware revision accepts config over SPP or only over USB.

## Sources
- [gpsbabel mtk format doc](https://www.gpsbabel.org/htmldoc-development/fmt_mtk.html)
- [bt747.org](http://www.bt747.org/)
- [MTKBabel / i-Blue 747 wiki (rigacci.org)](https://www.rigacci.org/wiki/doku.php/doc/appunti/hardware/gps_logger_i_blue_747)
- [gpswebshop: i-Blue 747 discontinued](https://gpswebshop.com/products/i-blue-747-bluetooth-gps-receiver-with-16mb-push-to-log-data-logger-auto-on-off-32-channels-waas-bluetooth-gps-usb-gps-google-integration)
- [FCC ID OUP940760101 (i-Blue 747)](https://fccid.io/OUP940760101)
