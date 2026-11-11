# LEDs2RAVE4 / Lunchbox Dream LED

> **Status**: Minimally verified (SPOTLED generation)
> **Protocol**: BLE
> **Manufacturer**: SPLED / Host No.4 Technology / Shenzhen I-ledshow

## Overview

The LED skins and panels sold by Lunchbox Packs with LEDs 2 RAVE 4 are not one device.
Different generations use different apps and incompatible BLE protocols. Identify the
app and GATT service before choosing a client.

| Generation | Design app | Controller / protocol |
|------------|------------|-----------------------|
| Dream LED Skin v1 | LED CHORD (`com.spled.pzse`) | SP107E, `0xFFE0` |
| Dream LED Skin 2.0 | SPOTLED (`com.led.spotled`) | Matrix panel, `0xFF20` |
| Dream Skin 3.0 early | SPOTLED | Matrix panel, `0xFF20` |
| Dream Skin 3.0 recent and future | iLEDColor (`com.led.iledcolor`) | Separate A950 protocol |

For DreamPanel v3, a horizontal serial-number display selects **iLEDColor**; vertical
selects **SPOTLED**. The tested iLEDColor unit had no FF20 service. Its recovered,
live-verified protocol is documented in [iLEDColor LED Matrix Panels](iledcolor-led-panel.md).

The v1 skin is an SPI pixel-strip product. Later products are matrix panels rendered by
the app. Geometry is per unit and must be queried or read from the advertisement, never
inferred from a marketing LED count.

## Hardware and validation

| Property | Value |
|----------|-------|
| v1 controllers | SP107E / SP110E, source-derived command tables |
| SPOTLED test unit | 96×16 RGB, advertised frame limit 20, 7280-byte receive buffer |
| iLEDColor test unit | 32×64, covered by the separate spec |
| Radio | BLE |
| Power | External USB power bank |

On 2026-11-07 this project completed all three SPOTLED information queries, a static
RGB upload and a single-frame native scroll-left upload. An eight-frame full-RGB
upload was rejected with response 254. SP107E, SP110E and other panel geometries were
not exercised.

## SPOTLED protocol

The canonical reference is [SPOTLED LED Panels](spotled-led-panel.md). The Lunchbox
service map is:

| UUID | Role | Live properties |
|------|------|-----------------|
| `0000ff20-0000-1000-8000-00805f9b34fb` | SPOTLED service | Confirmed |
| `0000ff21-0000-1000-8000-00805f9b34fb` | Commands and responses | Write without response, notify |
| `0000ff22-0000-1000-8000-00805f9b34fb` | Bulk data | Write without response |

1. Connect and enable FF21 notifications through the GATT client.
2. Send `04 14 00 00` (GetBufferSize) and await type 21.
3. Send `04 12 00 00` (GetDisplayInfo) and await type 19.
4. Optionally send `04 10 00 00` (GetVersion) and await type 17.

Notification values begin `[total_length][response_type]` followed by content. Strip
that two-byte header before applying the content parser; do not issue an ATT read and
do not write CCCD bytes to FF21 itself. Display dimensions and revision fields are
big-endian.

Uploads use a 15-byte data header and typed records on FF22. Write `MTU − 3` chunks and
react to device-driven ContinueSending offsets instead of assuming a fixed
`buffer_size ÷ chunk_size` threshold. Start succeeds with response type 2 and finish
with **type 4**, both status zero. PauseSending type 254 can indicate a bad MTU, but it
also rejected the eight-frame test payload; it is not a sufficient MTU diagnosis.

A 96×16 static frame and a single RGB frame with native scroll-left both completed
successfully at MTU 512 in ten chunks. The rejected eight-frame transfer means the
advertised 20-frame field is not a proven upload-size guarantee. AE30 and FF10 were
also enumerated but not used; their roles remain unknown.

## SP107E / SP110E commands

All commands are four bytes `[d0] [d1] [d2] [cmd]`, written to `0xFFE1`. These tables
remain source-derived rather than live-verified.

### SP107E

| Command | Bytes | Description |
|---------|-------|-------------|
| Power on | `00 00 00 aa` | Turn on |
| Power off | `00 00 00 bb` | Turn off |
| Set colour | `rr gg bb 0c` | Static RGB; `0x04` is colour order, not static colour |
| Set brightness | `vv 00 00 0a` | 0–255 |
| Set effect | `vv 00 00 08` | 1–180 dynamic, 181 static |
| Set speed | `vv 00 00 09` | 1–186 |
| Set sensitivity | `vv 00 00 13` | Audio gain |
| Query status | `00 00 00 02` | 26 bytes in two packets |

### SP110E

| Command | Bytes | Description |
|---------|-------|-------------|
| Power on | `00 00 00 aa` | Turn on |
| Power off | `00 00 00 ab` | Turn off |
| Set colour | `rr gg bb 1e` | Static RGB |
| Set brightness | `vv 00 00 2a` | 0–255 |
| Set effect | `vv 00 00 2c` | 1–120 dynamic, 121 static |
| Set speed | `vv 00 00 03` | **0–255**, not the SP107E 1–186 range |
| Query status | `00 00 00 10` | 12-byte reply |

Real SP110E hardware uses FFE0/FFE1. The older assignment of its opcodes to the FF20
SPOTLED transport was a misattribution.

## Discovery, setup and reset

Known name prefixes are `SP1`, `LBXDRMSKIN_LED_` and `SpotLED_`. FF20 identifies
SPOTLED when advertised, but some short advertisement samples contain only `0x1812`, so
do not require FF20 in every sample. Confirm the GATT layout after connecting.

No account, network provisioning or Bluetooth bond is required for these generations.
SPOTLED is deprecated on recent Android; LEDs2RAVE4 publishes a sideload guide and
suggests PIXELY GLOW. iLEDColor's online account is not needed for local control.

No factory-reset procedure is established. Power-cycling drops a connection but is not
a factory wipe. Rebinding is a fresh scan and connection, not a network rejoin.

## Open questions

- Live verification of SP107E/SP110E commands and properties.
- SPOTLED's actual multi-frame/resource limit and the roles of AE30 and FF10.
- Other geometries, text/font records, brightness/screen-mode writes and reset behavior.
- iLEDColor settings beyond its separately documented Connect/TestPass and upload flows.

## References

- [Lunchbox Dream LED Skin tutorial](https://www.lunchboxpacks.com/pages/dream-led-tutorial)
- [Dream LED Skin 2.0 setup](https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0)
- [LEDs 2 RAVE 4 DreamPanel](https://leds2rave4.com/products/dreamskin-v3-the-dreampanel)
- [Controller-generation guidance](https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app)
- [`python-spotled`](https://github.com/iwalton3/python-spotled)
- [UniLED](https://github.com/monty68/uniled)
- [SP110E protocol notes](https://gist.github.com/mbullington/37957501a07ad065b67d4e8d39bfe012)
