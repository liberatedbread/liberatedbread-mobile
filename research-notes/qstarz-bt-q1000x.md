# Qstarz BT-Q1000X GPS Logger — Research Notes

Category: Bluetooth Classic (SPP) GPS data logger. Covers the legacy consumer line: BT-Q1000, BT-Q1000X, BT-Q1000eX/XT (10 Hz racing variants), BT-Q818/XT, BT-Q1300S.

## Company / Cloud Status — ALIVE, LINE DISCONTINUED
- Qstarz International (Taiwan) is still in business but has pivoted to racing telemetry (LT-8000GT, BL-1000GT, BLE 4.0 devices) and a commercial logger (BL-1000ST). Site live as of 2026-08: [qstarz.com GPS products](https://www.qstarz.com/GPS_products.html), [racing.qstarz.com](https://racing.qstarz.com/Products/BT-Q1000eX.html).
- The entire BT-Q (Bluetooth Classic) consumer line is discontinued — e.g. BT-Q1000XT marked discontinued by resellers ([gpswebshop](https://gpswebshop.com/products/qstarz-bt-q1000xt-bluetooth-data-logger-gps-receiver-66-ch-agps-vibration-sensor-400k-waypoints)).
- No cloud dependency in the devices; the Windows config app **QTravel** is abandonware but replaceable by BT747/gpsbabel.

## Companion App
- **No Android app for the BT-Q line ever existed.** The current **QRacing** app (`com.qstarz.qracing`) supports only the BLE racing devices (LT-8000GT/BL-1000GT/LT-6000S) — verified by static triage below; it does NOT speak to BT-Q hardware.
- APK provenance (for completeness; out of category):
  - Package: `com.qstarz.qracing`, source: apkeep/apk-pure, XAPK 64,550,908 bytes, SHA-256 `e1a87dd59257ecdf5fdf57dd05189b2bccc66e97fc7e07394e3b60c6f7bea80e`.
  - Dex grep: `BluetoothGatt`/`BluetoothLeScanner` present; **zero** occurrences of SPP UUID `00001101-...` or any RFCOMM API (`createRfcommSocketToServiceRecord`/`BluetoothSocket`). Device strings: LT-8000GT, BL-1000GT, LT-6000S only. Confirms BLE-only.

## Transport — Bluetooth Classic SPP
- Bluetooth 1.2/2.0, SPP profile, UUID `00001101-0000-1000-8000-00805f9b34fb` ([Qstarz BT-Q1000X product page](https://www.qstarz.com/Products/GPS%20Products/BT-Q1000X-S.htm)).
- Pairing PIN: **0000** (standard for the line; third-party pairing lists for BT-Q1000XT confirm "0000").

## Protocol
- **Live position**: NMEA 0183 over SPP — gpsd/any NMEA parser, no vendor code.
- **Log download / config**: MediaTek MTK II chipset, **generic** MTK serial protocol (unlike Holux's variant). gpsbabel `mtk` format lists BT-Q1000, BT-Q1000X, BT-Q1000eX as **confirmed working** ([gpsbabel mtk doc](https://www.gpsbabel.org/htmldoc-development/fmt_mtk.html)); BT747 likewise. Config via PMTK packets; log dumped as MTK binary blocks (`mtk-bin`).
- Caveat from gpsbabel: some MTK loggers can't accept commands over Bluetooth (only USB) — Qstarz units are generally command-capable over SPP via BT747, but USB (internal Prolific/CP210x USB-serial) is the robust path.
- BT-Q1000eX/XT: 10 Hz track/5 Hz log, 400k waypoints ([linearconcepts review](http://www.linearconcepts.com/photography/reviews/qstarz-bt-q1000x-gps-travel-recorder)).

## Local Feasibility — CONFIRMED
Generic MTK protocol + generic NMEA SPP; best-documented logger family in this category. Works today with gpsd + gpsbabel/BT747, no cloud, no account.

## Open Questions
- Whether BT log-download is bidirectional on every BT-Q revision (gpsbabel caveat); USB fallback always works.
- QTravel's original PMTK sequences vs. BT747's — already equivalently covered by open tooling.

## Sources
- [Qstarz BT-Q1000X product page](https://www.qstarz.com/Products/GPS%20Products/BT-Q1000X-S.htm)
- [gpsbabel mtk format doc](https://www.gpsbabel.org/htmldoc-development/fmt_mtk.html)
- [bt747.org](http://www.bt747.org/)
- [gpswebshop: BT-Q1000XT discontinued](https://gpswebshop.com/products/qstarz-bt-q1000xt-bluetooth-data-logger-gps-receiver-66-ch-agps-vibration-sensor-400k-waypoints)
