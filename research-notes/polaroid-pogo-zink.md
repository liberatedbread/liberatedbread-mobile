# Polaroid PoGo (ZINK classic) — Research Notes

Covers the first-generation ZINK mobile printers on the same platform:
Polaroid PoGo Instant Mobile Printer (CZA-10011B, 2008), Polaroid GL10
(2011), Dell Wasabi PZ310 (2009). All discontinued; the PoGo line died
with the old Polaroid Corp (bankrupt 2008, brand passed to PLR IP /
licensees; ZINK Imaging itself was acquired by Foxconn in 2015 and ZINK
2x3 paper is still manufactured, so consumables remain available).

## Transport
- Bluetooth Classic 2.0 + EDR. **No BLE, no app required.**
- Printing is a plain **OBEX Object Push (OPP, UUID16 0x1105)** of a JPEG
  file. An XDA thread from 2009 notes the PoGo "doesn't support BPP and
  just uses OBEX" — i.e. OPP push, no Basic Printing Profile session.
- Pairing passcode is **6000** (documented in Polaroid's own
  "Tips for Bluetooth Printing from a Computer (PC)" PDF).
- USB (PictBridge) also available on the PoGo.

## Local control path (confirmed)
- Linux: `ussp-push <mac> image.jpg image.jpg` after pairing — used by the
  Raspberry Pi Instagram printer project (jonathanlking/Instagram-Printer-RP,
  BlueZ + ussp-push + python-bluetooth).
- Windows/macOS: pair with passcode 6000, then "Send to Bluetooth device"
  (OBEX push) per Polaroid's PC-printing PDF; macOS Bluetooth File
  Exchange works the same way.
- Android: any OBEX-capable file share ("Bluetooth share") to the paired
  printer. The era Polaroid PoGo Android app is not needed.

## Image requirements
- JPEG, roughly camera-sized; the printer scales. Community reports
  recommend resizing to ~1200x1800 or smaller to keep OBEX transfer fast
  (BT 2.0 EDR). Exact max dimensions not documented — open question.

## Cloud / account dependency
- None. Device predates companion-app/cloud models entirely.

## APK
- N/A — no companion app required. (A "Polaroid PoGo" Android app existed
  c. 2012 but was optional sugar and is long gone from stores; the OBEX
  path is the durable interface.)

## Open questions
1. Max JPEG dimensions / DPI behavior.
2. Whether GL10 and Dell Wasabi differ in any OBEX header requirements
   (expected identical — same ZINK platform).
3. Status/error feedback channel (none known — print failures are silent).

## Sources
- Polaroid "Tips for Bluetooth Printing from a Computer (PC)" PDF
  (passcode 6000, OBEX send flow): http://www.plawa.com/download/19111/Polaroid%20PoGo%20printing%20from%20PC%20GB.pdf
- XDA Forums, "Bluetooth to Polaroid Pogo" (OPP not BPP; pin 6000):
  https://xdaforums.com/t/bluetooth-to-polaroid-pogo.606290/
- github.com/jonathanlking/Instagram-Printer-RP (BlueZ + ussp-push print pipeline)
- JustAnswer passcode thread (default 0000 fallback reports):
  https://www.justanswer.co.uk/electronics/84bhe-will-find-bluetooth-passcode-polaroid-pogo-photo.html
