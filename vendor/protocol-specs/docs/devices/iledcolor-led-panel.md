# iLEDColor LED Matrix Panels

> **Status**: Minimally verified (Connect, TestPass, static and animated upload)
> **Protocol**: BLE
> **Manufacturer**: Shenzhen I-ledshow Technology Co., Ltd. (active)

## Overview

iLEDColor drives programmable RGB LED matrix panels, including recent LEDs 2 RAVE 4
DreamPanel v3 boards. It is a different protocol from SPOTLED, not a newer version of
it. A tested iLEDColor panel exposed no SPOTLED `0xFF20` service.

The vendor account is only needed for the online material library. Local discovery,
handshake and content upload work without an account. The protocol is recovered from
the vendor's published `led_bt_jl_ota` Flutter plugin, an independent Rust
implementation, and live owner-device validation on 2026-11-07.

## Hardware and identification

| Property | Value |
|----------|-------|
| Display | RGB LED matrix; geometry varies by panel |
| Geometry source | Big-endian width and height in manufacturer data |
| Tested geometry | 32×64, reported in the vendor field order; not a mounting-orientation claim |
| Radio | BLE |
| Companion app | iLEDColor (`com.led.iledcolor`) |
| Reset | Unknown |

Discovery signals are an `iledcolor-` name prefix, advertised
`0000af30-0000-1000-8000-00805f9b34fb`, or the documented manufacturer-data patterns.
AF30 is only an advertisement signal: fresh GATT discovery on the tested unit exposed
A950 and AE00, not AF30. Do not send commands to AF30.

For DreamPanel v3, a horizontal serial-number display selects iLEDColor; vertical
selects SPOTLED. Always confirm the GATT services rather than assuming from the retail
name.

## Initial setup and pairing

No provisioning, vendor account or Bluetooth bond is required.

1. Power the panel, scan and connect.
2. Discover service `0000a950-0000-1000-8000-00805f9b34fb` and subscribe to A953.
3. Write Connect (`54 0d 00 03 00 00 64`) to A951 without response. Expect
   `54 0d 00 04 00 00 00 65` on A953.
4. Test the six-byte password. The factory-default request is
   `54 0f 00 08 00 00 00 00 00 00 00 6b`. Response status 1 means accepted, 2 wrong
   password and 3 no password configured. The tested unit returned 3.
5. Read panel width and height from the advertisement before rendering.

Panels can have a user-set six-byte application password. That is separate from
Bluetooth pairing. If one is configured, use the owner's normal app flow rather than
guessing it.

**Factory reset** is unknown. Uploaded-program persistence across power cycles and a
clear/reset procedure were not tested. **Rebinding** needs no reset: disconnect the old
client, rediscover and connect from the new one.

## Protocol summary

| UUID | Role | Live properties |
|------|------|-----------------|
| `0000a950-0000-1000-8000-00805f9b34fb` | Display service | Confirmed |
| `0000a951-0000-1000-8000-00805f9b34fb` | Commands | Write without response |
| `0000a952-0000-1000-8000-00805f9b34fb` | Bulk program data | Write without response |
| `0000a953-0000-1000-8000-00805f9b34fb` | Responses and transfer progress | Notify |
| `0000ae00-0000-1000-8000-00805f9b34fb` | JieLi OTA service | Enumerated, not used |
| `0000ae01-0000-1000-8000-00805f9b34fb` | OTA writes | Write without response |
| `0000ae02-0000-1000-8000-00805f9b34fb` | OTA responses | Notify |

A951 command packets are:

```text
[54] [handle:u8] [length:u16 BE = payload + 2] [payload…] [checksum:u16 BE]
```

The checksum is the simple sum of every preceding packet byte. Known handles include
Continue `0x00`, EndStream `0x01`, program item `0x03`, StartStream `0x06`, brightness
`0x09`, LedEnable `0x0a`, Connect `0x0d`, SetPass `0x0e` and TestPass `0x0f`.
EndStream's fixed frame is `54 01 00 03 01 00 59`; payload status 1 is success.

StartStream's 11-byte payload is `[item CRC32C:4][logical transfer length:u32 BE][00 00 00]`, framed with handle 0x06, the normal u16 packet length and checksum. The complete worked request is `54 06 00 0d b8 a8 bd 77 00 00 48 4c 00 00 00 03 8f` (17 bytes): CRC32C `b8a8bd77`, transfer length `0x484c` = 18,508, then three reserved zero bytes and checksum `0x038f`.

Bulk chunks on A952 are complete `0x54` packets with a sequence, chunk length, data and
checksum. The validated static and animated uploads used 492-byte data chunks at MTU
517. Continue responses are 11 bytes with status at response byte 8. StartStream status
is not a chunk count; EndStream status is at response byte 4.

### Geometry and upload evidence

The tested manufacturer value reported width 32 and height 64. The spec's
`resolution_advertisement` offsets index the manufacturer value after its two-byte
company ID. Width and height are big-endian u16 fields at value bytes 5-6 and
3-4; the schema reads one byte per dimension, so the spec points at the low bytes
(offsets 6 and 4), which caps an advertised side at 255.

- A 6164-byte RGB static program completed StartStream, 13 acknowledged chunks and
  EndStream. Its stream had a CRC32C prefix and 6188 bytes total.
- An eight-frame, 200 ms-per-frame GIF-container upload completed four acknowledged
  chunks and EndStream, but restored the old program. It is transport evidence only,
  not proof of active animation.
- A corrected vendor-native three-frame animation used item type 2, a 22-byte item
  header (geometry, type, frame count, effect, speed, dwell, border and brightness),
  three 6144-byte raw row-major RGB frame buffers, then three two-byte big-endian
  frame-rate values (`00 01` = one frame per second). That is 22 + 18,432 + 6 =
  18,460 item bytes. A four-byte item CRC, four-byte programme header and 16-byte
  partition address table wrap it into an 18,484-byte stream body. StartStream is 17
  bytes and EndStream is 7, giving 18,508 logical transfer bytes before per-chunk
  overhead. It completed 38 chunks and stayed active; a static RGB fallback also
  visibly replaced the old text. This is the path clients should implement for
  animation.
- These are protocol and visual confirmations for one panel, not universal geometry or
  maximum resource-size claims.

Brightness, playlist management, password changes, maximum resource size, old-protocol
framing, factory reset and OTA remain untested. The OTA service is enumerated only; no
image format, entry command or recovery path is asserted.

## References

- [Vendor `led_bt_jl_ota` plugin](https://pub.dev/packages/led_bt_jl_ota)
- [Independent `iledcolor-rs` implementation](https://github.com/akkaisinabin/iledcolor-rs)
- [JieLi Android OTA SDK](https://github.com/Jieli-Tech/Android-JL_OTA)
- [LEDs 2 RAVE 4 controller-generation guidance](https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app)
- [SPOTLED protocol](spotled-led-panel.md), for the earlier incompatible generation
