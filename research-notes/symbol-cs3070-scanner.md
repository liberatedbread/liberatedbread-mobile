# Motorola/Symbol CS3000 Series (CS3070) — Research Notes

1D laser batch/Bluetooth barcode scanner (CS3000 = USB-only, CS3070 = USB + BT)
from the Symbol/Motorola line now owned by Zebra. **End-of-life product;
configuration is entirely via scanned barcodes — no app, no cloud. The classic
"plain SPP/HID works with generic tools" case.**

## Abandonment / status
- CS3000 series is end-of-life (superseded by the CS4070); Zebra still hosts the
  full Product Reference Guide, which doubles as the complete protocol/config
  reference: [Zebra CS3070 PRG (PDF)](https://www.zebra.com/content/dam/support-dam/en/documentation/unrestricted/guide/product/cs3070-prg-en.pdf).
- Zebra (and its 123Scan Windows utility) remain alive; nothing cloud-dependent
  has ever existed for this scanner. Orphaned surface = no modern mobile config
  app (never had one — config is scan-a-barcode).

## Hardware / transport / modes
Per the PRG and period how-tos ([tewarid.github.io: CS3070 on a PC](https://tewarid.github.io/2012/02/10/use-the-motorola-symbol-cs3070-barcode-scanner-on-a-pc.html),
[TEC-IT BlueBooking docs](https://www.tec-it.com/en/software/data-acquisition/Event_Check-In/overview/Default.aspx)):

- **USB batch**: 512 MB flash; scans stored in `ScannedBarcode/barcodefile.txt`,
  downloaded over USB — fully offline.
- **BT HID keyboard wedge**: pairs to anything (incl. iOS, which sees it as a
  keyboard); keystrokes + programmable suffix/prefix. Zero software needed.
- **BT SPP**: "For CS3070 scanners, to pair to a Bluetooth-enabled PC or laptop
  via SPP: press the scan button (+) to wake the scanner, then scan the
  Bluetooth Serial Port [config barcode]" (Zebra PRG). Scanner streams each
  barcode as ASCII over the RFCOMM channel.
- All config (symbologies, beeper, prefix/suffix, BT mode, PIN) is done by
  scanning barcodes printed in the PRG — the manual is the entire "protocol spec".

## Companion app
- None ever existed for mobile. Desktop 123Scan optional. Nothing to fetch.

## Feasibility
- **CONFIRMED / trivial.** Pair (HID or SPP per scanned config barcode), read
  ASCII. Linux: `rfcomm` or just use HID mode and read keystrokes. This is a
  documentation task, not an RE task — the PRG is authoritative and public.

## Open questions
- Exact SPP service UUID (expected standard `00001101` — confirm during first pairing).
- SPP-mode data terminator defaults and whether ACK/flow-control exists in SPP mode.

## Sources
- [Zebra CS3000 Series Product Reference Guide](https://www.zebra.com/content/dam/support-dam/en/documentation/unrestricted/guide/product/cs3070-prg-en.pdf)
- [Use the Motorola Symbol CS3070 barcode scanner on a PC (tewarid.github.io, 2012)](https://tewarid.github.io/2012/02/10/use-the-motorola-symbol-cs3070-barcode-scanner-on-a-pc.html)
- [TEC-IT BlueBooking — supported BT scanners incl. CS3070](https://www.tec-it.com/en/software/data-acquisition/Event_Check-In/overview/Default.aspx)
