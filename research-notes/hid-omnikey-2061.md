# HID OMNIKEY 2061 Bluetooth — Research Notes

Portable contact smart-card reader (ISO 7816 T=0/T=1, EMV 2000 L1) with
**Bluetooth Classic** + USB, from HID Global (ASSA ABLOY). **Confirmed
discontinued by the manufacturer; fully local device — no cloud ever existed.**

## Abandonment / status
- HID Global's own product page: "This product has been discontinued"
  ([hidglobal.com/products/2061](https://www.hidglobal.com/products/2061), accessed 2026-08).
- Resellers confirm EOL with "NO REPLACEMENT"
  ([usmartcards.com](https://www.usmartcards.com/hid-omnikey-2061-contact-card-bluetooth-reader-r20610000-1-end-of-life),
  [cardquest.com](https://cardquest.com/store/products/262/view),
  [barcodesinc.com](https://www.barcodesinc.com/hid/omnikey-2061-bluetooth-reader.htm)).
- HID Global is alive; this is a single orphaned product. There is no cloud
  component at all — the only vendor software was a PC/SC driver.

## Hardware / transport
- Full-size contact smart card slot, 10k insertion durability, battery-powered,
  two status LEDs. Datasheet: [CardLogix mirror PDF](https://www.cardlogix.com/wp-content/uploads/HID-Omnikey-2061-Bluetooth-Smart-Card-Reader-datasheet.pdf).
- Bluetooth Classic with **128-bit encrypted link** (vendor claim) + USB fallback.
- Driver model: PC/SC ("ready for 2.01"); datasheet lists Windows support and
  mentions Linux. The BT link tunnels smart-card APDUs; on Windows the vendor
  driver presents a virtual PC/SC reader over the BT COM port.

## Companion app
- None (desktop driver only; nothing on Play Store to fetch).

## Feasibility
- **MEDIUM.** The reader is an SPP device at the transport level; the open
  question is the APDU framing over the BT link and whether the vendor's
  "encrypted link" is a pairing-level or application-level scheme.
- No public open-source driver for the BT path found (pcsc-lite/libccid cover
  USB readers; the 2061's USB fallback mode may be CCID-standard and immediately
  usable on Linux — worth testing, since that side-steps BT entirely).
- If the BT framing is a thin wrapper (likely, given era and the Windows
  virtual-COM approach), a small Python SPP->PC/SC bridge is realistic after one
  USB-pcap/BT-snoop session against the vendor Windows driver.

## Open questions
- BT SDP records: SPP UUID and/or custom service UUID; pairing PIN behavior.
- Whether the USB fallback enumerates as standard CCID (would make local use trivial).
- Framing of APDUs over the BT link; nature of the 128-bit link encryption.
- naviGO software (HID on the Desktop) dependency: cosmetic only, not required
  for reader operation.

## Sources
- [HID Global product page (discontinued notice)](https://www.hidglobal.com/products/2061)
- [OMNIKEY 2061 datasheet (CardLogix mirror)](https://www.cardlogix.com/wp-content/uploads/HID-Omnikey-2061-Bluetooth-Smart-Card-Reader-datasheet.pdf)
- [uSmartCards EOL listing](https://www.usmartcards.com/hid-omnikey-2061-contact-card-bluetooth-reader-r20610000-1-end-of-life)
