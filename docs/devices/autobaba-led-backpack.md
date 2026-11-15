# AUTOBABA LED Backpack

> **Status**: Minimally verified (queries, brightness, static and animated upload)
> **Protocol**: BLE; Wi-Fi on some related LOY SPACE products
> **Manufacturer**: LOY SPACE / popled.cn (active)

## Overview

A programmable full-color LED backpack using the LOY SPACE protocol family, also seen
in NYAN GEAR and other panels. The detailed spec is
`device-specs/devices/autobaba-led-backpack.yaml`.

On 2026-11-07 this project used the documented protocol on one 64×64 unit. It completed
a device-information query, a reversible brightness test, a read-only telecontrol query,
and static plus eight-frame raw-GIF uploads. Every required acknowledgement was
sequence-matched, checksum-valid and status zero.

## Hardware and identity

- Advertised names begin `YS` or `TL` and include a device serial. This is a platform
  match, not proof of an AUTOBABA controller revision. A `LOY` name belongs to the
  separate [LOYPRO candidate](loypro-led-display.md).
- Main display service: `0000fff0-0000-1000-8000-00805f9b34fb`.
- Display writes: `0000fff2-0000-1000-8000-00805f9b34fb`, write-without-response only.
- Display notifications: `0000fff1-0000-1000-8000-00805f9b34fb`, notify.
- The tested information reply reported 64×64 geometry, fixed brightness 7 and remote
  support. Unit-specific identity and CID values are intentionally not published.

Rediscover by exact advertised name plus FFF0 rather than persisting an old address.
A separate `5833ff01-9b8b-5191-6142-22a4536ef123` service was present but unused. It is
an SBH OTA candidate only; do not send display, authentication or firmware commands
there without a compatible capture and recovery path.

## Setup and pairing

Power the backpack and connect directly. No account, network provisioning or Bluetooth
bond is established for the BLE display path. Do not infer Wi-Fi merely because the
generic app supports it. The information reply's `pwd` token indicates password support,
not whether a password is configured; use the owner's normal flow if one is set.

Subscribe to FFF1 before querying or sending a command. Use FFF2 with
`response=False`. No factory reset is established; power-cycling only drops the
connection and is not a factory wipe.

## Information query and geometry

This example asks for device information, panel parameters, power state and brightness.
Sequence 1 is only a worked example; a client increments its sequence counter.

```text
aa 55 ff ff 0e 00 01 00 c1 03 0a 00 1b 00 04 00 06 00 ff 03
```

The tested unit returned one complete 151-byte, checksum-valid reply. In panel TLV
`0x1b`, a leading panel-data-type byte is followed by **little-endian** width and
height. `00 40 00 40` therefore means 64×64. This is deliberately different from
SPOTLED's big-endian dimensions.

The reply's literal model field and version/capability strings are preserved in the
research evidence but are not a retail-model identification. The initial 64×64 app
state was not used as geometry evidence.

## Brightness

Fixed brightness uses TLV `06 02 00 <level>`. The app offers 1–15 and maps zero to 15;
only 6 and 7 were tested. Sequence 2 selected 6, sequence 3 restored 7, and a later
information query confirmed the restored value:

```text
aa 55 ff ff 0a 00 02 00 c1 02 06 02 00 06 da 03
aa 55 ff ff 0a 00 03 00 c1 02 06 02 00 07 dc 03
```

Both returned mode `0x82`, matching sequence and status zero. This validates the
command path and device-reported value; no visual brightness change was independently
recorded.

## Frame and TLV format

The inner frame begins `AA 55 FF FF`, followed by little-endian length, sequence,
flags/mode, TLV records and a little-endian additive checksum. Do not prepend the
optional outer stream-record length to an individual GATT write.

| Encoding | Value length |
|---|---|
| `LL` below `0x80` | `LL` bytes |
| `81 LL` | `LL` bytes, for 128–255 |
| `82 LL LH` | Little-endian 16-bit length, for 256 and above |

Thus `13 81 c4` means TLV type `0x13` with 196 bytes of value. The official richer
resource builder normally uses 960-byte logical chunks, a 997-byte TLV ceiling and a
big-endian 16-bit chunk count. Those logical chunks are not GATT writes.

The simplified raw-GIF route is now confirmed on this unit:

- 427-byte static GIF: READY, three 196-byte value chunks, FINALIZE.
- 4558-byte, eight-frame GIF at 200 ms per frame: READY, 24 chunks, FINALIZE.
- MTU 247 and 243-byte GATT writes; every required ACK had status zero.

READY example: `aa 55 ff ff 0a 00 09 00 c1 02 08 02 00 00 dd 03`.
FINALIZE example: `aa 55 ff ff 0b 00 0f 00 c1 02 36 03 01 00 00 14 04`.

The simplified raw-GIF packet is `aa55ffff | one-byte length | 00 <index> 00 | 27-byte sequence | total_chunks | 00 <index> 00 | c4000013 | 81c4 | 196-byte padded GIF data | little-endian u16 checksum`. The first six payload bytes are `GIF89a`; pad every chunk, including the last, with zeros to exactly 196 bytes. Length is `0xed` = 236 data bytes + 1, so a complete packet is 243 bytes (47 bytes of overhead). The spec's `worked_chunk_hex` is a complete index-0 example with checksum `0d09`.
Do not generalize these example sequence numbers or this chunk size to every firmware.
A device-originated mode-06 message was also observed and remains undecoded.

## Remote and maintenance boundaries

A read-only telecontrol query (`34 03 02 aa bc`) returned remote model 43711 and 17
ordinary button mappings to programs 76–92. Four special records are not assigned
invented meanings. The unit reported `remote` but not `car_linkage`, so this is remote-
button configuration evidence, not proof of accelerometer or vehicle-triggered
animations.

Power, rotation, playback, deletion, password, reset, official-app MTU behavior and the
secondary maintenance protocol remain unverified.

## References

- [LOY SPACE on Google Play](https://play.google.com/store/apps/details?id=com.yskd.loywf)
- [Official LOY SPACE download page](https://app.popled.cn/loy/loyspace/index.html)
- [`stared/nyan-led-skills`](https://github.com/stared/nyan-led-skills), related hardware and raw-GIF route
- [DCloud `phy-ble-ota` profile](https://ext.dcloud.net.cn/plugin?id=27776), secondary UUID-family context only
