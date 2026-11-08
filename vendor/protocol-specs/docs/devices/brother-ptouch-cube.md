# Brother P-touch Cube Label Printers

> **Status**: Spec Available (untested)
> **Protocol**: Bluetooth Classic SPP / RFCOMM
> **Manufacturer**: Brother Industries, Ltd. (active)

## Overview

This family covers the PT-P300BT, PT-P300BTz, PT-P710BT, PT-P715eBT,
PT-P910BT and PT-N25BT. The established control path is a Classic serial
connection carrying Brother's raster and status commands; it is not BLE GATT.
The machine-readable spec includes per-model differences, command frames,
reply layouts, media handling and source links:
`device-specs/devices/brother-ptouch-cube.yaml`.

Nothing here has been replayed by this project. Protocol facts come from
Brother's documentation, public clients and static analysis, and are marked
`reported` or `hypothesis` individually in the spec.

## Setup and pairing

1. Insert a TZe cassette, close the cover and power the printer on.
2. Open the host's Bluetooth settings and look for `PT-` followed by the model
   and the last four serial digits, for example `PT-P710BT1234`.
3. Pair with it. Enter `0000` if the host asks for a PIN.
4. Open RFCOMM to SPP UUID `00001101-0000-1000-8000-00805f9b34fb`, wait about
   500 ms, then use the spec's invalidate, initialize and status commands. A
   normal status reply is 32 bytes.

The PT-P300BT, PT-P710BT and PT-P715eBT may accept an insecure unbonded
socket, but this has not been tested. Use the documented pairing flow rather
than depending on that possibility. On the PT-P910BT, Bluetooth can be
reenabled from idle by holding Power for about nine seconds, releasing, then
pressing it twice quickly.

The printer serves one host connection at a time. Disconnect the old phone or
remove the printer from its Bluetooth list before pairing another host.
CoreBluetooth cannot open this RFCOMM control channel; the spec records the
per-platform compatibility boundary.

## Factory reset and rebinding

No reset is established for the PT-P300BT or PT-P710BT. Do not assume that a
power-button sequence on another model applies to them.

For the **PT-P910BT**, the vendor guide documents this unverified-by-us
procedure:

1. With the printer idle, hold Power for about nine seconds until the Power
   LED flashes green, then release.
2. Hold Power for about nine seconds again until it flashes green rapidly,
   and release while it is flashing rapidly.
3. The LED flashes orange and then remains orange while the printer returns
   to idle.

The guide calls this a reset of the printer's internal memory. Whether it
also removes bonded hosts is unclear. Rebinding in all cases is simply a new
Classic pairing after disconnecting the previous host.

## Protocol summary

Requests and responses travel as a byte stream with no GATT characteristics.
The spec declares the RFCOMM profile, framing, initialization order, status
fields and print commands. It also distinguishes commands established by
public working clients from model-specific hypotheses. Do not send a print
job until the cassette geometry and variant have been selected correctly.

## References

- [PT-P710BT User's Guide](https://download.brother.com/welcome/docp100362/pt-p710bt_eng_ug_03.pdf)
- [PT-P300BT User's Guide](https://download.brother.com/welcome/docp100262/ptp300bt_useng_usr_d018t1001a_05.pdf)
- [PT-P910BT User's Guide](https://support.brother.com/g/s/es/htmldoc/ptouch/p910bt/uken/PDF/PDF.pdf)
- [Brother Bluetooth connection FAQ](https://support.brother.com/g/b/faqend.aspx?c=us&lang=en&prod=p300bteus&faqid=faqp00100300_000)
- [Ircama/PT-P300BT](https://github.com/Ircama/PT-P300BT)
- [robby-cornelissen/pt-p710bt-label-maker](https://github.com/robby-cornelissen/pt-p710bt-label-maker)
- [Common Bluetooth Classic Patterns](../protocols/bluetooth-classic-common.md)
