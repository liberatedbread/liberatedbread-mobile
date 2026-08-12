# Brother PocketJet PJ Series — Research Notes

Brother's A4 thermal mobile printers: PJ-522/523, PJ-622/623,
PJ-662/663, PJ-673 (all discontinued), and the still-supported
PJ-722/723/762/763(MFi)/773 and newer PJ-8x2/8x3. Bluetooth Classic SPP
(+USB). Brother is alive and hosts drivers + command documentation —
this entry exists because the PJ-5xx/6xx fleet is EOL and everywhere on
the used market, and because the protocol is publicly documented
(known-protocol category).

## Transport
- Bluetooth Classic **SPP** (0x1101) + USB. PJ-673 era is BT 2.1;
  PJ-763MFi adds iAP2 for iOS.
- Pairing PIN: configurable via Brother's settings tool; default per
  user guide (typically "0000" or last-4-of-serial on some firmware —
  confirm per unit; TBD).
- Discovery name: "PJ-6xx" / "PJ-7xx" model string.

## Protocol (public)
- Brother publishes the **Command Reference** for the PJ series
  (support.brother.com): two modes —
  - **ESC/P** (Epson-compatible page mode, text + bit image), and
  - **Raster mode** (Brother raster graphics, shared lineage with
    P-touch raster).
- Windows/macOS CUPS drivers available from Brother; Linux printing via
  CUPS filter or raw ESC/P over `/dev/rfcomm0`.
- `pt-p700`-class community tooling does NOT cover PJ raster — but the
  vendor command reference is complete enough to write a spec directly.

## Local control feasibility
- **Confirmed.** Fully offline: pair over SPP, send ESC/P. No account,
  no cloud, no app required (Brother iPrint&Scan is optional).
- Value to the repo: a clean-room spec derived from the public command
  reference + an rfcomm print recipe would retire the Windows-driver
  dependency for the EOL models.

## APK
- N/A — no required companion app. Desktop drivers + public command
  reference are the interface.

## Open questions
1. Default BT PIN per model/firmware (confirm PJ-673 vs PJ-763).
2. ESC/P subset deltas between PJ-6xx and PJ-7xx (command reference
   covers both; note model quirks).
3. Bluetooth power-save wake behavior on PJ-673 (field reports of
   sleep-drop; needs unit test).

## Sources
- Brother PJ-800 series User's Guide (points to Command Reference on
  support.brother.com):
  https://www.brother.eu/-/media/product-downloads/devices/nordics/eu_en/printers/portable-printers/pj-800-series-user-guide.pdf
- Brother support FAQ listing PJ-5xx/6xx as legacy models (driver
  pages still hosted):
  https://support.brother.com/g/b/faqend.aspx?c=ca&lang=en&prod=9700eus&ftype3=100149&faqid=faqp00000106_000&pfs=1
- Brother Mobile Solutions PocketJet page (current models):
  https://brothermobilesolutions.com/products/printers/pocketjet/pj763/
