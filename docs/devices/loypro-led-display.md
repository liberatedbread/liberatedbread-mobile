# LOY / LOYPRO Helmet and B3 Tail-Light LED Displays

> **Status**: Minimally verified query, plus decoded official-app upload/DFU capture
> **Protocol**: BLE, AA55 binary TLVs
> **Manufacturer**: LOY / YSKJ OEM family

## Identity and family boundary

The LOYPRO app (`com.yskj.loypro`) accepts advertised names beginning **LOY**.
Reviewed LOY PLAY and AUTOBABA/LOY SPACE versions accept only `YS` and `TL`.
Keep the separate LOYPRO candidate rather than expanding another spec's filter.

The captured product is a **B3 motorcycle tail light** supplied with bicycle and
helmet mounts; its firmware family contains `MTYB3BGR`. This does not make every
LOY-named product the same retail shell. The older Shining Display/TR platform
uses FA02 and is covered by [TIRO LED Helmet Display](led-helmet-display.md),
not by this protocol.

**FFF0 is not a device type.** Keep
`0000fff0-0000-1000-8000-00805f9b34fb` in the GATT declaration, never as an
independent scan matcher.

## Setup and read-only identification

No account, provisioning or pairing was required in the live query or official
capture. The device reports optional password support; if an owner enabled one,
use the normal app flow rather than guessing or bypassing it.

1. Rediscover the LOY name; do not rely on a stale address.
2. Confirm `0000fff2-0000-1000-8000-00805f9b34fb`
   **write-without-response** and `0000fff1-0000-1000-8000-00805f9b34fb`
   **notify**.
3. Subscribe to FFF1 and issue this 20-byte `dev_info_all` query on FFF2 with
   `response=False`:

```text
aa 55 ff ff 0e 00 01 00 c1 03 0a 00 1b 00 04 00 06 00 ff 03
```

Increment sequence numbers in a real client and reassemble replies by declared
AA55 length. The checksum-valid 159-byte reply established 48×16 geometry,
fixed brightness 15, power type 1, firmware V2.9.1#V18 and capabilities `pwd`,
`remote`, `car_linkage`, `brake`, `HS:2`, `MTU:512` and `power`. The MTU token
is a capability, not the negotiated value. Stop if the dialect differs.

No factory reset is established. Rebinding is a fresh scan and connection; do
not use delete-program or firmware messages as reset/identification probes.

## AA55 transport

| Offset / field | Encoding |
|---|---|
| Header | `aa 55 ff ff` |
| Length | u16 LE; sequence + flags + command type + payload + checksum; packet bytes = length + 6 |
| Sequence | u16 LE; can be reused by later operations |
| Flags | `c1` host command, `81` ordinary response |
| Command types | `02` program/control, `03` query, `04` resource upgrade; responses `82`, `83`, `84`, notification `06` |
| Checksum | u16 LE sum of **every preceding byte**, including the AA55 header, modulo 65536 |

The capture negotiated MTU 512/517 and host ATT values were at most 509 bytes.
Join ATT fragments **before** checking AA55 length/checksum or matching an ACK.
A logical 960-byte media chunk is a TLV inside an AA55 packet, not one ATT write.

TLV lengths are one byte below `0x80`, `81 LL` for 128–255, and `82 LL LH`
(little-endian u16) for larger observed values.

Ordinary `82` ACKs are the exception to TLV payloads: byte 10 is one raw status
byte. A captured successful ACK for sequence `0x0016` is
`aa 55 ff ff 07 00 16 00 81 82 00 1d 04`. Match flags `81`, type `82`, the
request sequence and status zero before continuing. Nonzero is a rejection;
no nonzero device error values or error-code taxonomy were captured. The YAML
includes a synthetic nonzero vector solely to test that rejection path.

## Stored program upload

**`08 02 00 00` deletes/replaces program zero. It is not an upload-ready probe.**
The earlier delete-only READY attempt therefore asked the wrong operation and
its timeout did not disprove GIF support. Choose the stored slot deliberately.

1. Send a program header with replacement (`08`), save (`09`), program (`0c`),
   play configuration (`1c`), region (`0d`) and geometry (`1d`) TLVs.
2. Send a graphic item with item (`0e`), effect (`14`) and media declaration
   (`11`) TLVs.
3. Send media in ascending zero-based chunks. Every chunk repeats `09 01 01`
   and the graphic item's program (`0c`), region (`0d`) and item (`0e`) values
   before tags `12` and `13`. Tag `12` carries total count, index and maximum
   chunk size (960 in the capture) as LE16 values plus `00`; tag `13` carries
   the media bytes.
4. After **every** type-2 packet, wait for response `82` with the matching
   sequence and status `00`. All 84 such packets in the capture were ACKed.
5. Finalize with tag `35`: zero-based program byte, 20-byte resource key and
   u32 LE timestamp. Require its ACK too. Deduplicate retransmitted chunks by
   program/item/index.

Raw GIF bytes stay GIF. Other graphics use the separate YSTP01 image encoder;
text uploads are rendered image pages, often ending in a blank page, not a
simple string command. Locally generated resource IDs use eight characters
from the **one-based app/UI program number** (`wire_program_index + 1`) plus
zero padding, followed by MD5 of the input description. Wire program zero thus
uses prefix `10000000`, not `00000000`. Decode the resulting 40 hex characters
to 20 bytes. Hash original input bytes, not converted YSTP01. Captured cloud
keys may use another scheme; they are identifiers, not credentials.

### YSTP01 media encoding

YSTP01 starts with this 15-byte header; all integer fields are little-endian:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 6 | ASCII `YSTP01` |
| 6 | 2 | Width in pixels |
| 8 | 2 | Height in pixels |
| 10 | 2 | Page count |
| 12 | 2 | Raw delay value; its time scaling is unknown |
| 14 | 1 | Bits per pixel: 8 or 24 are capture-confirmed |

An 8-bit stream has 256 three-byte RGB palette entries immediately after the
header. A 24-bit stream has no palette and stores each pixel as R, G, B. Pages
follow consecutively without per-page headers, with rows ordered top to bottom
and pixels left to right. Palettized indices are packed least-significant bit
first; each row occupies `(width * depth + 7) // 8` bytes and starts on a byte
boundary. Emit zero in unused high padding bits. Total media length is
`15 + palette_bytes + pages * height * row_stride`.

The spec's `ystp01.synthetic_vectors` block provides reproducible 24-bit and
8-bit media. `scripts/test_loypro_led_display.py` independently encodes,
decodes and hashes both vectors using only the standard library. Text
rasterization, delay units and other YSTP depths or variants remain unverified.

### Geometry and media evidence

- Device-information and TLV canvas: **48×16**.
- Captured animated GIF: **48×15**, 65 frames, 4551 bytes in five logical chunks.
- Two custom 24-bit single-page images, three coloured text sequences and four
  static 48×16 GIF resources were also reconstructed.
- The offline builder reproduces all eight packets of the captured GIF upload
  byte-for-byte. This proves the official protocol path, not a new third-party
  hardware write or visible rendering by our client.

Tag `36` controls playback model/index/program-ID lists. Its value has one-byte
`model` at offset 0, one-byte `index` at offset 1, then zero-based program IDs
as one byte each. Preserve the exact list order; the app displays each ID plus
one. For example, sequence 17 selects model 0, raw index 2 and programs 0–9:
`aa 55 ff ff 14 00 11 00 c1 02 36 0c 00 02 00 01 02 03 04 05 06 07 08 09 56 04`.
Model 1 loops and other models select single-play behavior. The raw index's
numbering semantics are not established. Short type-6 tag-`36` notifications
are playback data, **not accelerometer axes**.

## Firmware update — advanced only

A distinct type-4 resource-upgrade stream transferred 360448 bytes in 377
chunks, with 377 matching type-`84` ACKs. Like ordinary ACKs, each upgrade ACK
has flags `81` and one raw status byte at offset 10; require the request sequence
and status zero before continuing. Captured sequence-zero success is
`aa 55 ff ff 07 00 00 00 81 84 00 09 04`. The first chunk carries text metadata
with model, sum16 and a resource ID; the reconstructed image matches both that
sum16 and its MD5. Device information changed from **V2.9.1#V18** before the
transfer to **V2.9.1#V24** after disconnect/reconnect.

MD5/sum16 are integrity checks, not proof of a vendor signature or safe image
for another unit. **Do not replay the captured stream, use the normal image
uploader as DFU, or guess recovery.** Wrong-image and interrupted-update
behavior are unknown.

## Vehicle inputs and remaining questions

The unit reports `remote`, `car_linkage`, `brake` and `power`; the updated image
also contains an MSA311 driver string. App-assignable programs are 67 left,
68 right, 69 brake, 70 hazard and 71 reverse. None of this establishes an
integrated accelerometer, wired input, remote mechanism or motion map. A
capture actuating one input at a time is still needed.

Other open items are visible third-party rendering, arbitrary geometry/media,
password setup, reset, maintenance services in other firmware states and safe
firmware recovery.

## References

- [LOY / LOYPRO on Google Play](https://play.google.com/store/apps/details?id=com.yskj.loypro)
- [`ztrawhcs/yskj-led-sign`](https://github.com/ztrawhcs/yskj-led-sign), independent family client tested on another device
- [AUTOBABA protocol relative](autobaba-led-backpack.md), with a different YS/TL identity
