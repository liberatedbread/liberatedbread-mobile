# Microchip/Roving Networks RN-41/RN-42 SPP Module — Research Notes

Classic Bluetooth serial modules (RN-41 Class 1, RN-42 Class 2) sold bare and as
hobby breakouts: SparkFun BlueSMiRF Gold/Silver/HID, Bluetooth Mate Silver/Gold,
Parallax RN-42, plus countless OEM embeds. **Confirmed EOL; no app, no cloud —
this is the canonical "plain SPP just works" device.**

## Abandonment / cloud status
- Microchip PCN **MFOL-24SJQF382** (2022-04-27): "The RN41xx, RN-27xx, RN42xx,
  RN52xx and RN-24xx device families will be moving to End of Life (EOL) status
  effective today" ([DigiKey mirror of PCN](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/4233/MFOL-24SJQF382.pdf)).
- SparkFun lists all BlueSMiRF / Bluetooth Mate boards as retired
  ([github.com/sparkfun/BlueSMiRF](https://github.com/sparkfun/BlueSMiRF)).
- Roving Networks (original designer) was acquired by Microchip in 2012; the
  recommended replacements (RN4871, BM70) are BLE-only — no SPP successor.
- No cloud has ever been involved; "abandonment" = silicon + official
  documentation/tooling (Roving Networks config Windows utilities) orphaned.

## Transport / protocol
- Bluetooth 2.1 + EDR, SPP (UUID `00001101-...`), plus RN-42-HID firmware variant
  presenting as a BT keyboard/mouse HID.
- Config is a documented AT-style command set over the UART side (or over the
  air while unconnected): enter command mode with `$$$`, exit with `---`;
  `SM,0/1/2` slave/master/auto, `SN,<name>`, `SP,<pin>`, `SU,<baud>`, etc.
  Reference: Roving Networks "Bluetooth Advanced User's Guide" (widely mirrored;
  SparkFun hookup guides link copies).
- Default pairing PIN `1234`; default UART 115200 (module) / 9600-115200 on
  breakouts depending on firmware config.
- Host side needs nothing more than `rfcomm`/`pyserial` on Linux or the Android
  `BluetoothSocket` SPP API.

## Companion app
- None exists or is needed — configuration is AT commands over serial. The
  orphaned vendor artifacts are the Windows config utilities and the Roving
  Networks user manuals (survive via mirrors, e.g. SparkFun hookup guides).

## Feasibility
- **TRIVIAL/confirmed.** This is the reference case the repo category exists to
  document: pair -> open SPP channel -> bytes. Millions of these are embedded in
  legacy industrial gear, and the modules themselves remain plentiful on
  surplus/used markets.

## Open questions
- None blocking. (Optional: catalog the firmware-variant matrix — standard SPP,
  HID, iAP/MFi "Bluetooth Mate" builds — since firmware flashing is now
  impossible without Microchip tooling.)

## Sources
- [Microchip PCN MFOL-24SJQF382 (EOL, 2022-04-27)](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/4233/MFOL-24SJQF382.pdf)
- [SparkFun BlueSMiRF repo (retired boards list)](https://github.com/sparkfun/BlueSMiRF)
- [Microchip RN42 datasheet](https://www.microchip.com/bin/downloaddocument?contentid=en572993)
