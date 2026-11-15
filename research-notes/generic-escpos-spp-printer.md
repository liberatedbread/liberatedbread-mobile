# Generic 58mm ESC/POS SPP Thermal Printers — Research Notes

The flood of cheap 58mm Bluetooth receipt printers sold under dozens of
brands: Zjiang ZJ-5802 / ZJ-5805 / POS-5801, Goojprt MTP-II / MTP-3 /
PT-210, "MPT-II", MUNBYN IMP001, Aibecy, etc. This is the
**Bluetooth Classic reality-check entry**: no RE needed, no cloud, no
account — they are plain SPP serial printers speaking an ESC/POS subset,
and the bundled Android apps are abandonware-quality junk that the repo
can replace outright.

## Transport
- Bluetooth Classic 2.0/3.0/4.0 **SPP** (UUID 0x1101), always-on
  discoverable, default name like "MTP-2", "BlueTooth Printer", "Printer001".
- **PIN: 0000** (Goojprt driver-CD note: "If you have to enter a pin use
  0000"); 1234 on some clones. No bonding state — re-pair freely.
- Also expose USB-CDC/serial on most units.

## Protocol
- **ESC/POS subset**: standard init (`1B 40`), text, raster bit image
  (`1D 76 30`), feed/cut, some support `GS (` Chinese-font variants and
  EPSON-style barcodes. Quirks: 32 chars/line (58mm, font A), max raster
  width 384 dots, no status readback on many clones.
- Works out of the box with **python-escpos** over `/dev/rfcomm0`
  (`printer.File`) — confirmed pattern in python-escpos issues/discussions
  (e.g. #517, #643).
- Android local-print alternative: "RawBT" app (ru.a402d.rawbtprinter)
  acts as a print service for these — no vendor app required.

## Local control feasibility
- **Confirmed, trivial.** `rfcomm bind /dev/rfcomm0 <MAC> 1` then write
  ESC/POS bytes. The entire vendor software stack (Windows driver CD,
  flaky Android apps like "Goojprt"/"MHT"/"Printer") can be ignored.

## APK
- No single canonical app — vendors ship assorted rebadged print apps.
  Skipped deliberately: the protocol is standard ESC/POS; an APK would
  add nothing. (GOOJPRT-Printer-Driver GitHub repo is a straight copy of
  the vendor driver CD for reference.)

## Vendor status
- Shenzhen Zijiang Electronics (zjiang.com) and Goojprt both still
  manufacture these (2026 listings active on Alibaba) — the hardware is
  NOT abandoned; what is disposable is the app/driver layer. Documented
  here because these printers are ubiquitous in exactly the flea-market /
  second-hand channel this repo serves.

## Open questions
1. Per-clone ESC/POS command coverage matrix (cut, buzzer, drawer kick).
2. Some "4.0" units are dual-mode BT Classic + BLE — BLE side is a
   separate (cat-printer-adjacent) topic.

## Sources
- Goojprt driver-CD mirror (PIN 0000 note, MTP-II/MTP-3):
  https://github.com/1rfsNet/GOOJPRT-Printer-Driver
- MPT-II user manual (BT interface behavior):
  https://www.ht-instruments.it/media/filer_public/f0/4e/f04e8540-41bc-46d3-ae45-10e98973ab45/mpt-ii_user_manual.pdf
- Zjiang ZJ-5802 product listing (BT 2.0/3.0/4.0, ESC/POS):
  https://www.etradeasia.com/supplier-332563/Shenzhen-Zijiang-Electronics-Co-Ltd/product-detail-1131833/58mm-bluetooth-USB-port-thermal-printer-for-android-IOS-mobile-phone-5802.html/1000
- python-escpos Bluetooth usage discussions:
  https://github.com/python-escpos/python-escpos/discussions/517
