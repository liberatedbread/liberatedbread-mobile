# SPOTLED LED Panels

> **Status**: Minimally verified, plus official-app multi-frame capture
> **Protocol**: BLE (legacy FF20 protocol; reported OTA and PIXELY extensions)
> **Manufacturer**: Host No.4 Technology (Chengdu) Co., Ltd. / generic OEM
> **Manufacturer Status**: Unsupported

## Overview

SPOTLED drives full-colour and monochrome LED matrix hats, badges, backpack
skins, chest panels and flexible signs under many reseller names. It includes
the [Lunchbox / LEDs 2 RAVE 4 Dream Skin](leds2rave4-lunchbox-led.md) 2.0 and
early 3.0. Recent DreamPanel v3 boards instead use
[iLEDColor](iledcolor-led-panel.md), an incompatible protocol.

SPOTLED 1.9.4 (2023) is the last release on Android and iOS. Local BLE control
does not depend on its account or cloud. PIXELY GLOW is a reseller-suggested
alternative; its reported v2/v3 extensions are not interchangeable with the
capture-proven legacy protocol below.

## Discovery and pairing

Known name prefixes are `LBXDRMSKIN_LED_` and `SpotLED_`. FF20 is useful when
advertised but can be absent from short advertisements. One tested panel also
advertised `00001812-0000-1000-8000-00805f9b34fb` and company `0x05D6`; **do not
match every HID-over-GATT device on 0x1812**. Confirm FF20/FF21/FF22 after
connecting.

Pairing is **not required**, but it is not true that pairing never happens:

- Bondless community clients work without a PIN or persistent bond.
- The official app initiates legacy Just Works pairing.
- The captured panel selects No Bonding, no MITM and no LTK distribution; the
  phone then enables encryption for that connection.

This is transient, unauthenticated pairing—not a durable owner credential.
Close the old central before reconnecting; power-cycle only for connection
recovery, not as a claimed factory wipe.

## Bootstrap

1. Connect and negotiate MTU; discover FF21/FF22 under FF20.
2. Enable FF21 notifications through the GATT client. If writing the CCCD
   directly, discover it and use the standard `01 00`, not bytes written to
   FF21 itself.
3. Send Version `04 10 00 00`, DisplayInfo `04 12 00 00` and BufferSize
   `04 14 00 00`, awaiting response types 17, 19 and 21.
4. Optionally query animation/text capability with `04 1a 00 00` (response 27).

The official app's fuller order is version → display → capability →
playlist/object queries → receive capacity. The three queries above are
sufficient for this documented upload path. Notifications are not ATT
read-back responses.

### Response layouts

Query responses 17, 19, 21 and 27 begin
`[length][type][serial_be16][status]`, with payload from byte 5 and success
status zero.

| Response | Full bytes | Fields after the common query header |
|---|---:|---|
| Version (17) | 15 | hardware type u16 BE, hardware version u32 BE, firmware version u32 BE |
| DisplayInfo (19) | 13 | width u16 BE, height u16 BE, colour type u8, advertised frames u8, brightness u8, font count u8 |
| BufferSize (21) | 9 | receive capacity u32 BE |
| Animation/text capability (27) | 9 | animation frame capacity u16 BE, character capacity u16 BE |

Newer capability responses may append a length-gated u32 storage size at byte 9;
that extension is reported, not present in the captured base response.

Transfer replies use two other layouts. Captured type-2 start and type-4
finish acknowledgements are seven bytes:
`[length][type][serial_be16][status][command_type_be16]`. Require status zero
and matching serial and command type. ContinueSending type 255 instead is ten
bytes: `[length][type][serial_be16][command_type_be16][resume_offset_be32]`.
It has no status byte; match its response type, serial and command type, then
use the offset at byte 6 rather than applying either status-bearing layout.
PauseSending type 254 is separate and was not captured.

Newer DisplayInfo responses may append a length-gated light-state byte. The
tested geometry was 96×16, colour type 255, advertised frame count 20,
brightness 100 and receive capacity 7280 bytes; none is a universal constant.

Colour types recovered statically are 16 = 1-bit mono, 128 = RGB332,
238 = RGB565 and 255 = RGB888. Type 49 selects the older RGB888 lattice record
6. Only RGB888/type-96 is capture-confirmed.

## BLE services

| UUID | Role | Properties / confidence |
|------|------|-------------------------|
| `0000ff20-0000-1000-8000-00805f9b34fb` | Legacy display service | Confirmed |
| `0000ff21-0000-1000-8000-00805f9b34fb` | Commands/responses | Write without response, notify; confirmed |
| `0000ff22-0000-1000-8000-00805f9b34fb` | Bulk display data | Write without response; confirmed |
| `0000ff10-0000-1000-8000-00805f9b34fb` | OTA service | Reported, not exercised |
| `0000ff11-0000-1000-8000-00805f9b34fb` | OTA instructions | Write/notify; reported |
| `0000ff12-0000-1000-8000-00805f9b34fb` | OTA data | Write/notify; reported |

Legacy FF21 frames are `[u8 length][u8 command_id][u16_be serial]
[u16_be command_type][u32_be command_length]`. Fixed queries use only the first
four bytes. The command channel has no checksum; do not add another framing
layer. Vendor serial counters wrap at 255 despite wider wire fields.

## Data records and checksum

FF22 legacy payloads have a 15-byte header: big-endian header length 15,
command `0x8004`, serial, content length and checksum. Records follow as
`[u32_be length][u16_be type][fields][checksum]`.

| Type | Meaning |
|---:|---|
| 2 / 3 / 4 / 5 | Colour / character / character string / word stock |
| 6 / 7 / 8 / 9 | Lattice frame / time / effect / speed |
| 10 / 11 / 13 | Number bar / animation / font glyph |
| 14 | Brightness, 0–100 |
| 15 | Screen mode (value + two padding bytes): normal, upside-down, mirror, both |
| 96 | Dynamic colour frame: width, height, depth, bitmap |

Effects are 0 none, 1 up, 2 down, 3 left, 4 right, 5 stack, 6 expand, 7 laser.
The checksum sums the covered bytes; if the sum exceeds `0xff`, negate with
`(~sum)+1` and keep the low byte. A smaller sum is emitted unchanged.

### Multi-frame animation container

The captured animation is not three bare frame records. Its record order is:

1. **FrameAnimation**, 9 bytes: length, type 11, u16 BE frame count, checksum.
2. That many **DynamicColorFrame** records. Each has length, type 96, u16 BE
   width and height, u8 depth, the bitmap and checksum. RGB888 pixels are R,G,B
   per pixel, left to right then top to bottom. Record length is
   `12 + width * height * (depth / 8)`; a 96×16 RGB888 frame is 4620 bytes.
3. **Time**, 10 bytes: length, type 7, u8 time type, u16 BE milliseconds,
   checksum. The capture uses type 0 and 200 ms.
4. **SpecialEffects**, 8 bytes: length, type 8, one effect byte, checksum.

Thus three 96×16 frames have `9 + 3 * 4620 + 10 + 8 = 13887` bytes of records;
the separate 15-byte data header brings the payload to 13902 bytes. The spec's
`synthetic_three_frame_vector` uses solid red, green and blue frames and has
SHA-256 `b5ea06e26a8327c98d799fd9c5df1d7587ec828b006010e9010fd61e0f53d5d6`.
`scripts/test_spotled_led_panel.py` builds and parses that complete payload,
including every checksum and the 7280-byte receive-window split.

## Upload flow control

1. Send SendingDataStart and require type 2 with status zero and matching
   serial and command type.
2. Serialize the complete payload once, then slice it into raw writes no larger
   than `MTU − 3`. Do not add a length or checksum to each ATT chunk.
3. Pace writes and respond to the device. The official app chose 182-byte
   writes after negotiating MTU 512; negotiated MTU alone does not select the
   application's chunk size.
4. ContinueSending type 255 carries the command type at bytes 4–5 and the
   offset to **resume from** at bytes 6–9. Use that offset, not the client's
   cursor, and do not apply either status-bearing response layout.
5. Send SendingDataFinish and require **type 4 with status zero and matching
   serial and command type**, not type 2. PauseSending type 254 alone does not
   diagnose MTU.

The official capture paused after exactly 7280 data bytes and resumed both
13902-byte three-frame transfers successfully.

## What the new capture proves

A supplied 2026-11-10 official-app capture contains seven reconstructed data
transactions, including font/text records, a one-frame RGB888 image and two
three-frame RGB888 animations. All declared lengths and checksums validate and
all finish responses are successful. Decoded 96×16 frames match camera images,
including RGB channel order. Each RGB888 frame record is 4620 bytes.

This resolves the older invisible-static-upload and three-frame capability
questions. Earlier custom-client three/eight-frame attempts failed, so their
serialization difference still needs investigation; the advertised 20-frame
field is not a proven arbitrary transfer limit. Other geometries,
monochrome/RGB332/RGB565, settings writes and factory reset remain open.

## OTA and PIXELY GLOW boundaries

Static app analysis identifies FF10/FF11/FF12 and this OTA sequence:

1. Command 80 presents whole-image CRC-16 (poly `0x1021`, init zero, MSB-first)
   and a u24 big-endian image length.
2. Command 81 obtains the acknowledgement window.
3. Command 82 streams image blocks on FF12 with per-window ACKs.
4. Command 83 asks whether the update completed.

OTA command IDs are little-endian 16-bit values. Metadata comes from the vendor
API, but no OTA session, image-signature policy, exact-model compatibility or
interrupted recovery was captured. **Do not replay an image from this documentary
sequence alone.**

PIXELY GLOW retains the legacy path on the captured panel and includes separate
protocol v2/v3 framing and request IDs. Those static extensions are recorded in
the YAML under `protocol_details.pixely_glow_extensions`; they need their own
advertisement-gated captures and must not be sent to every SPOTLED unit.

## Setup, reset and rebinding

No account or network provisioning is needed. Scan, connect, subscribe and
query. Rebinding is a fresh connection from another controller after closing
the old one; no persistent LTK bond was established in the capture. No factory
reset is established, and power-cycling is not claimed to erase content.

## References

- [`python-spotled`](https://github.com/iwalton3/python-spotled)
- [`spotled-cli`](https://github.com/dpeckett/spotled-cli)
- [`esp32-spotled`](https://github.com/nexzoic/esp32-spotled)
- [SPOTLED getting started](https://spotled.app/getting-started/)
- [PIXELY GLOW installation guidance](https://www.ravebeetle.com/pages/install-the-spotled-app)
- [Lunchbox Dream LED Skin 2.0 setup](https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0)
