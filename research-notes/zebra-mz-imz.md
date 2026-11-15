# Zebra MZ / iMZ Series Mobile Printers — Research Notes

Zebra MZ 220 / MZ 320 (2" and 3" receipt printers) and their successors
iMZ220 / iMZ320. **MZ series discontinued 2013-11-29**; the whole
MZ/iMZ family is now **End Of Service Life — Zebra provides no service
or support** (Zebra support KB). Large installed base in field-service /
delivery; units are cheap on the used market. Zebra the company is alive
— this is product-EOL, not company-dead. No cloud was ever involved.

## Transport
- Bluetooth Classic **SPP** (serial port profile) + USB.
- iMZ adds MFi (iOS) support; MZ is SPP-only.
- Pairing: Zebra's official answer — "the mobile printers with the
  exception of the EM220 do not have a PIN preprogrammed" — i.e. pair
  with no PIN / SSP just-works; older firmware accepts 0000/1111.
- Friendly name defaults to the printer serial number.

## Protocol (public, no RE needed)
- **CPCL** (Comtec/Zebra Printer Control Language) — native; Zebra
  publishes the full CPCL Programming Guide.
- **ZPL II** — supported on iMZ (and MZ with later firmware); ZPL II
  Programming Guide is public.
- Print path from Linux is literally:
  `rfcomm bind /dev/rfcomm0 <mac>; cat label.cpcl > /dev/rfcomm0`
  or `python-escpos`-style byte writes. Windows: Zebra Setup Utilities
  + standard COM-port driver.
- SGD (Set/Get/Do) config commands over the same channel (`! U1 ...`)
  cover Bluetooth name, power-save, media settings.

## Local control feasibility
- **Confirmed, trivial.** Line-mode CPCL/ZPL text + graphics; no app, no
  account, no cloud, documentation public. This is the archetypal
  "generic tools work" Bluetooth Classic device.
- Batteries are the main failure point (third-party replacements exist).

## APK
- N/A — no companion app; Zebra's tooling is desktop (Zebra Setup
  Utilities) and the protocol manuals are the spec.

## Open questions
1. Exact CPCL/ZPL feature split per firmware revision (MZ vs iMZ).
2. WLAN variants exist (avoid confusion: this note is the BT models).

## Sources
- Zebra KB "Meaning of LED's on the MZ and iMZ Series Mobile Printers"
  (states EOSL for MZ220/320, iMZ220/320):
  https://support.zebra.com/article/Meaning-of-LED-s-on-the-MZ-and-iMZ-series-mobile-printers
- Zebra KB "What is the default bluetooth PIN":
  https://support.zebra.com/article/What-is-the-default-bluetooth-PIN
- Discontinuation dates (MZ220/320: 2013-11-29):
  https://www.bcpmedia.com.au/discontinued-zebra-products/
- MZ 220/320 user guide mirror:
  https://www.hant.pl/instrukcje/drukarki-etykiet/zebra/instrukcja-obslugi-drukarki-etykiet-zebra-mz-220-320.pdf
- iMZ220/320 datasheet (BT for iOS/Android/WinMobile):
  https://www.iware.si/wp-content/uploads/2017/02/Specifikacije_iMZ320.pdf
