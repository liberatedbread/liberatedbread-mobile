# LOYPRO / B3 matching, live query and official-capture findings

Research reviewed 2026-11-07; live query and official-app capture 2026-11-08.
Unit addresses, raw identity components and user media are deliberately not
retained in the clean-room spec. The authoritative implementation is
`device-specs/devices/loypro-led-display.yaml`; sanitized vectors are checked by
`scripts/test_loypro_led_display.py`.

## Identity conclusion

The match is the **LOY / LOYPRO (`com.yskj.loypro`) LED-display family**, because
LOYPRO explicitly accepts `LOY` in its scan filter. Reviewed LOY PLAY and
AUTOBABA/LOY SPACE versions accept only `YS` and `TL`. FFF0 alone had produced
16 equally poor candidates; it is shared by unrelated LED panels, thermometers,
battery monitors, OBD adapters, treadmills and serial modules and must not be an
independent matcher.

The captured product is a B3 motorcycle tail light supplied with bicycle and
helmet mounts. Its firmware family contains MTYB3BGR. The older Shining
Display/TR platform uses FA02 and is a different protocol, so this capture does
not update the TIRO/Shining spec.

## Live read-only confirmation

A fresh 2026-11-08 session enumerated FFF0 with FFF2 write-without-response and
FFF1 notify, subscribed, and issued the source-derived 20-byte `dev_info_all`
query. The 159-byte response has valid sequence, declared length and additive
checksum.

Panel TLV `1b` decodes little-endian as **48×16**. Brightness is 15 and power
type is 1. Firmware capability tokens include `pwd`, `remote`, `car_linkage`,
`brake`, `HS:2`, `MTU:512` and `power`; the MTU token is a capability, not a
negotiated measurement. Only query/subscription was used in that session—no
display, configuration, pairing, reset or firmware write.

## Official B3 capture

The supplied official-app capture has 7086 packets and SHA-256
`63cf7e1a4abfbcad815b51b14e221c9be0784048deac3d54be6c9cf5a681c084`. Offline
analysis reassembled ATT fragments into 969 host/device AA55 packets and
validated every length/checksum. It establishes:

- custom 24-bit YSTP01 images and palettized/24-bit rendered text pages;
- four static GIF resources and a 48×15, 65-frame animated GIF;
- ascending logical media chunks with maximum 960 bytes and matching `82` ACKs
  for all 84 ordinary type-2 packets;
- resource finalization (`35`) and playback model/index/program lists (`36`);
- a 360448-byte type-4 upgrade in 377 chunks with 377 matching `84` ACKs and
  firmware identity V2.9.1#V18 before, V2.9.1#V24 after reconnect;
- an offline builder reproducing all eight packets of the captured GIF program
  byte-for-byte.

This is capture confirmation, not a new third-party hardware write or visible
rendering claim. No new hardware writes were made during analysis.

## Upload correction

`08 02 00 00` is a delete/replace-first-program TLV, **not upload READY**. The
old delete-only attempt does not establish missing GIF support and must not be
repeated as a harmless probe.

The real sequence is program header → graphic item → ascending media chunks →
resource finalization, waiting for the matching status-zero ACK after every
packet. Every media chunk repeats the save/program/region/item TLV prefix before
`12`/`13`. Ordinary `82` and upgrade `84` ACKs each carry one raw status byte at
offset 10, not a TLV; the spec includes captured success and synthetic nonzero
frames. Raw GIF remains GIF; other graphics use YSTP01. The information/TLV
canvas is 48×16 while the captured GIF is 48×15; preserve those distinct sizes.
All five captured YSTP01 streams fit the recovered header, palette and packed
page-length formula. The spec now declares that encoding, with synthetic
24-bit and 8-bit round-trip vectors; delay units and other variants stay open.

Locally generated resource IDs use an eight-character prefix from the one-based
app/UI program number (`wire_program_index + 1`) plus MD5 of the input
description, encoded as 20 bytes. Wire program zero uses `10000000`. Hash
original input bytes, not converted YSTP01. Captured cloud resources can use
unrelated keys and zero timestamps; these are identifiers, not secrets.

Playback tag `36` has one-byte model and index fields followed by zero-based
program IDs; the app displays those IDs plus one. The spec carries the captured
sequence-17 selection packet and a synthetic media-chunk composition vector.

## Vehicle linkage and sensors

`remote`, `car_linkage`, `brake` and `power` are confirmed capabilities. The
upgraded image contains an MSA311 driver string. Neither proves a physical
trigger mechanism. Ordinary assignable programs are 67 left, 68 right, 69
brake, 70 hazard and 71 reverse; they are not five demonstrated gestures.
Short type-6 `36` notifications decode as playback, not accelerometer axes.
A dedicated one-input-at-a-time capture is still required.

## Remaining unknowns

- Visible third-party upload rendering, arbitrary geometry/media and all slots.
- Vehicle bindings, live events, sensor values/scaling and motion mappings.
- Password configuration, reset and optional maintenance services.
- Wrong-image/interrupted-update recovery and compatibility with other images.
- Whether intermittent advertising is policy, power state or another central.

## Sources

- Sanitized dev_info_all query/response, 2026-11-08.
- Official B3 control capture and offline decoder/replay outputs, 2026-11-08.
- LOYPRO 2.1.04, LOY PLAY 1.7.15 and LOY SPACE 1.2.19 filter/protocol analysis.
- [`ztrawhcs/yskj-led-sign`](https://github.com/ztrawhcs/yskj-led-sign), family
  evidence on another named unit.
