# SPOTLED LED Panels

> **Status**: Minimally verified (queries, static RGB and native single-frame scroll)
> **Protocol**: BLE
> **Manufacturer**: Host No.4 Technology (Chengdu) Co., Ltd. / generic OEM
> **Manufacturer Status**: Unsupported

## Overview

SPOTLED is an OEM design app for full-color and monochrome LED matrix panels. It drives
LED hats, badges, backpack skins, chest panels and long flexible signs under many
brands. Products include the [Lunchbox / LEDs 2 RAVE 4 Dream Skin](leds2rave4-lunchbox-led.md)
2.0 and early 3.0.

The app renders text, images and animations on the phone and uploads bitmap records.
It is unmaintained, but local control does not depend on its cloud account. Recent
DreamPanel v3 boards instead use [iLEDColor](iledcolor-led-panel.md), which is a
confirmed incompatible protocol with no FF20 service on the tested unit.

## Hardware and discovery

| Property | Value |
|----------|-------|
| Display | Full-color or monochrome LED matrix; geometry varies |
| Geometry source | GetDisplayInfo, not the retail model name |
| Colour depth | `16` monochrome, `255` RGB in DisplayInfo |
| Radio | BLE |
| Pairing | None |
| App | SPOTLED (`com.led.spotled`, App Store id 1564039607) |

There is no universal advertised-name prefix. Known prefixes are `LBXDRMSKIN_LED_` and
`SpotLED_`. FF20 is useful when advertised, but some short advertisement samples omit
it, so match a known name as well and confirm the GATT layout.

## Connection bootstrap

1. Connect and negotiate MTU; fall back to 23 only when negotiation is unavailable.
2. Enable FF21 notifications through the GATT client. Discover the CCCD if writing it
   directly; do **not** write descriptor bytes to FF21 itself.
3. Discover FF21 and FF22 under FF20.
4. Send GetBufferSize `04 14 00 00` and await type 21.
5. Send GetDisplayInfo `04 12 00 00` and await type 19.

Notification values begin `[total_length][response_type]`, followed by the documented
content. The content lengths are 13 for Version, 11 for DisplayInfo and 7 for
BufferSize. These are notifications, not ATT read-back responses.

## BLE services

| UUID | Role | Live properties |
|------|------|-----------------|
| `0000ff20-0000-1000-8000-00805f9b34fb` | SPOTLED service | Confirmed |
| `0000ff21-0000-1000-8000-00805f9b34fb` | Commands and responses | Write without response, notify |
| `0000ff22-0000-1000-8000-00805f9b34fb` | Bulk data | Write without response |

Command frames on FF21 are `[uint8 length][uint8 command_id][uint16_be serial]
[uint16_be command_type][uint32_be command_length]`. The three Get commands are fixed
four-byte frames. SendingDataStart (`0x01`) and SendingDataFinish (`0x03`) are ten-byte
frames with variable serial, type and payload length. Do not add another characteristic
framing layer.

## Data records

FF22 payloads have a 15-byte header: big-endian header length 15, command type
`0x8004`, serial, content length and one-byte checksum. Typed records follow as
`[uint32_be length][uint16_be type][fields][checksum]`.

| Type | Meaning |
|------|---------|
| 2 | Colour |
| 3 | Character |
| 4 | Text |
| 5 | Font |
| 7 | Time |
| 8 | Effect: 0 none, 1 up, 2 down, 3 left, 4 right, 5 stack, 6 expand, 7 laser |
| 9 | Speed |
| 10 | NumberBar |
| 11 | Animation |
| 13 | FontCharacter |
| 14 | Brightness, 0–100 |
| 15 | Screen mode: normal, upside-down, mirror, both |
| 96 | Frame: width, height, depth 1 mono / 24 RGB, bitmap |

The checksum is the covered byte sum, negated when it exceeds `0xff`, truncated to one
byte. Text may be rendered client-side into animation frames or sent as Character
records (approximately 72 characters); custom glyphs use FontCharacter first.

## Upload flow control

1. Send SendingDataStart and require response type 2 with matching serial/type and
   status zero.
2. Write FF22 in `MTU − 3` chunks. Pace writes and react to device responses rather
   than assuming a fixed `buffer_size ÷ chunk_size` wait threshold.
3. ContinueSending type 255 carries the offset to resume from; use it instead of the
   client cursor.
4. Send SendingDataFinish and require **response type 4 with status zero**, not type 2.

PauseSending type 254 can mean chunks are too large or too small, but an eight-frame
full-RGB test was also rejected with it. Pause is therefore not a sufficient MTU
diagnosis or a statement of the exact resource limit.

### Live evidence and remaining gaps

On 2026-11-07 a 96×16 RGB unit answered all three queries and accepted a static frame
and a native scroll-left frame at MTU 512 in ten chunks. The static upload needed no
Continue notification. An eight-frame, 37010-byte payload was rejected with response
254, so the advertised 20-frame field is not treated as a guaranteed transfer limit.
On 2026-11-08, a smaller 13910-byte three-frame upload was rejected the same way at
both 2500 ms and the vendor-capped 1000 ms. Material query/upload and screen-on control
also failed to return successful object responses, so no autonomous playlist was
created. A static fallback was acknowledged but not visually confirmed.

Other geometries, monochrome mode, text/font records, brightness/screen-mode writes,
multi-frame uploads, playlist behavior, factory reset and OTA remain unverified. AE30
and FF10 were present on that unit but unused; their roles are unknown.

## References

- [`python-spotled`](https://github.com/iwalton3/python-spotled)
- [`spotled` on PyPI](https://pypi.org/project/spotled/)
- [SPOTLED on Google Play](https://play.google.com/store/apps/details?id=com.led.spotled)
- [SPOTLED on the App Store](https://apps.apple.com/us/app/spotled/id1564039607)
- [Lunchbox Dream LED Skin 2.0 setup](https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0)

## Contributors

- @iwalton3 — `python-spotled` protocol reverse engineering
