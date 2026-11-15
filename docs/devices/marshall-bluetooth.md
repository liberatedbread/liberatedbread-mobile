# Marshall Bluetooth Headphones, Earbuds and Speakers

> **Status**: Spec Available (untested)
> **Protocol**: BLE GATT for control; optional Bluetooth Classic audio pairing
> **Manufacturer**: Zound Industries / Marshall (active)

## Overview

The spec covers Motif II A.N.C., Major IV, Monitor III A.N.C., Willen,
Stanmore and Woburn families:
`device-specs/devices/marshall-bluetooth.yaml`. It separates ordinary Classic
audio pairing from the encrypted LE control link, maps modern and legacy
characteristic UUIDs, and records model-specific reset and firmware-update
boundaries. Nothing has been replayed by this project.

## Setup and pairing

The simplest route does not require a prior Classic audio pairing:

1. Power the product on. For earbuds, place them in the case with the lid
   open.
2. Scan for the LE advertisement named after the model with a ` [LE]`
   suffix, such as `MOTIF II A.N.C. [LE]` (or carrying company ID `0x065A`),
   and connect to that LE address. The suffix on its own is not
   Marshall-specific.
3. Bond with Just Works / NoInputNoOutput. No PIN is needed. On BlueZ,
   register an agent before calling `Pair()`.
4. Discover service `fa302d24-d775-4343-b9ed-8cc68ace3284`. Resolve each
   function by UUID across all services: modern
   `0000{code}-1337-1dea-feed-c0ffee70c0de` first, then its documented legacy
   `0000aaXX-0000-1000-8000-00805f9b34fb` alias. Hide a function the product
   does not expose.

The vendor app can instead pair Classic audio first and then start the LE
bond. Some firmware derives the LE keys from the Classic bond; other models,
including Motif II A.N.C., still require the separate LE bond. Proprietary
characteristics refuse unbonded access.

## Factory reset and rebinding

Reset clears user settings and remembered pairings, not installed firmware.
Afterwards, remove both the ordinary entry and the ` [LE]` entry from each
host before pairing again.

| Model | Vendor-documented procedure | Indicator |
|---|---|---|
| Motif II A.N.C. | Both earbuds in the open case; hold the case button for 10 seconds | Case LED turns purple |
| Monitor III A.N.C. | With headphones on, hold M-button and ANC together for 5 seconds | LED turns purple |
| Willen | With speaker on, hold the Bluetooth button for 7 seconds | Indicators turn off and the speaker restarts |

These procedures come from the manuals and were not run by this project. Do
not apply them to a different model merely because it shares the control
protocol.

A new client can pair using the normal LE route. The manuals document up to
eight remembered Classic hosts on some products; LE bond capacity and
eviction behaviour are unknown.

## Protocol summary

The LE control link carries battery, EQ, noise-control, playback and
model-specific functions. UUID schemes and payload support vary, so model
detection and a modern-to-legacy fallback are mandatory. Firmware update uses
different mechanisms across the family; the spec identifies Qualcomm GAIA
and other update paths only to the depth established by evidence and does not
offer a generic flashing recipe.

## References

- [Motif II A.N.C. full manual](https://www.marshall.com/on/demandware.static/-/Library-Sites-SharedLibrary-Marshall/default/dwe0dadd06/images/cms-pages/user/Marshall_Motif_II_ANC_R0_13_en.pdf)
- [Monitor III A.N.C. full manual](https://downloads.ctfassets.net/javen7msabdh/Y4lwjaW2ma8v33Kx2ZXCz/d55009139a27c6786e45675a034af6e2/Marshall-Monitor-III-ANC-All-Languages.pdf)
- [Major IV quick-start guide](https://assets.ctfassets.net/javen7msabdh/vzQ3XbFS8MEIRU6gF5j7T/b8664637be2ff28ff88ae319dd3651ae/Marshall-Major-IV-User-Manual.pdf)
- [Willen full manual](https://assets.ctfassets.net/javen7msabdh/1m805BGMfjJjFGpJelki0v/c00e7d3c50426305e7ff4b82d391b0ed/Marshall-Willen-User-Manual.pdf)
- [rabbit-aaron/marshall-stanmore-2](https://github.com/rabbit-aaron/marshall-stanmore-2)
- [elrobertocarlos/marshall_bluetooth_speaker](https://github.com/elrobertocarlos/marshall_bluetooth_speaker)
