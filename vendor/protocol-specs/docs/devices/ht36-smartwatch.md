# HT36 Smartwatch

> **Status**: Spec Available (from an open client whose author ran it against one watch; no capture here, not run against hardware by this project)
> **Protocol**: BLE
> **Manufacturer**: Unbranded (YC nadal SDK platform)
> **Manufacturer Status**: Active (the GloryFitPro companion app is still listed on Google Play; the vendor cloud publishes no firmware for this watch)

## Overview

The HT36 is a budget colour-screen smartwatch sold without a brand for use
with the GloryFitPro phone app. The app bundles a vendor SDK from YC (the
SDK calls itself "nadal"), and the watch speaks that SDK's command set over
an ordinary BLE GATT link. Nothing in this page needs the vendor app or its
cloud: the watch answers any central that connects and subscribes. There is
no pairing, no bond and no application-layer login.

Everything here comes from [tcsenpai/ht36](https://github.com/tcsenpai/ht36),
an MIT-licensed TypeScript client written from a decompile of the vendor app.
Its author ran it against an HT36: pushed notifications rendered on the
wrist, the watch buzzed on command, battery and device info decoded, and a
day of fitness history and a night of sleep came back. Every byte in the
machine-readable spec is therefore `verification: reported`. This project
holds no capture, FCC grant or manual for the watch and has not connected to
one.

The machine-readable spec is
[`device-specs/devices/ht36-smartwatch.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/ht36-smartwatch.yaml).

**In scope:** discovery by name; the command envelope; battery, device info,
find/vibrate and the find-state query; set-time (documented as **not
working** on this firmware); GPS position push; the chunked XOR-8 transfers
for the notification switches, notification push and weather push; and
fitness, sleep and workout history sync.

**Out of scope:**

- **Firmware update.** The update characteristic
  `e49a3002-f69a-11e8-8eb2-f2801f1b9fd1` is documented as do-not-write, with
  no bytes. Upstream warns that a stray byte there can brick the watch.
- **Watch-face upload.** The `.bin` format is described; the transfer is
  not, and it does not work upstream anyway once the watch's face slots are
  full.
- **AGPS almanac and route uploads**, the health-measurement setters and
  every SDK feature upstream has not mapped (call alerts, camera remote,
  alarms, reminders, music).
- **Other YC-SDK watches sold under other names.** They may share the whole
  GATT table (see [Identification](#identification)) and still differ.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | HT36 (advertised name). The firmware calls itself `AT364D` followed by `V` and a six-digit build, and reports device type `NAL-WB00` |
| Chipset | Not established. Upstream's early notes say Telink TLSR8232/8258, inferred only from the `e49a…-f69a-11e8-8eb2-f2801f1b9fd1` UUID base; that base is not Telink's published OTA service (`00010203-0405-0607-0809-0a0b0c0d1912`). Upstream's later watch-face notes name an Actions ATS3085-class part, which fits the screen and face-slot sizes better |
| Radio | BLE |
| Screen | Colour, 240 × 296 as the watch reports it; watch faces target 240 × 240 |
| GNSS | The watch answers an ephemeris query with a GPS/BeiDou/Galileo list, which upstream reads as an on-board multi-GNSS receiver; not otherwise established |
| Companion app | GloryFitPro (Android `com.yc.gloryfitpro`) |
| Bluetooth address | The one unit on record sits in OUI `78:02:B7` (ShenZhen Ultra Easy Technology Co., Ltd.). One unit is not enough for a prefix matcher |
| FCC ID | None found. No FCC grant, label photo or manual naming one has turned up for the HT36 |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `HT36` (exact) |
| Passphrase protection | not_applicable |
| Confidence | medium (one public implementation ran it; not run here) |

There is nothing to provision: no account, no Wi-Fi, no bond. Every
connection runs the same steps:

1. Wake the watch and make sure the GloryFitPro app is not connected to it.
2. Scan for the exact local name `HT36` and connect.
3. Enable notifications on `000034f2-0000-1000-8000-00805f9b34fb` (service
   `000056ff-0000-1000-8000-00805f9b34fb`). The watch shows a spinner and
   vibrates once: it has entered its connected-to-app state.
4. Wait about 500 ms, then write commands without response to
   `000034f1-0000-1000-8000-00805f9b34fb`. The battery query `01 a4 aa 16`
   is a good first write: the reply starts `01 a4 aa 16` and carries the
   percentage at byte 7.

Nothing else arrives on `34f2` for about **19 seconds** after subscribing;
after that the watch sends a pair of frames roughly every 10 s. A client
that listens for a few seconds and sees nothing has not failed.

**Factory reset**: not established. The vendor SDK has a factory-reset call,
but its bytes were not mapped and no manual for the HT36 has been found.
Upstream's advice to hold the button for 10–15 s (or let the battery run
down) is for recovering a frozen watch, a forced restart, not a reset, and
it is generic advice for this class of watch rather than something confirmed
on the HT36.

**Rebinding**: nothing a client does binds the watch. The vendor app
registers the watch to its cloud account, but the watch answered the open
client without being unbound. To move to a new client, stop the vendor app
(or turn off Bluetooth on its phone) so it cannot hold the link.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | Not applicable |
| One central at a time | Unknown |
| One bond at a time | No (nothing is bonded) |
| Confidence | medium |

**Entering pairing mode**: not needed. The watch is connectable whenever it
is awake and no other central holds it.

The open client connects from macOS with a plain GATT connection and never
pairs or bonds, and every command on this page worked that way. The vendor
SDK also has application-layer pairing-request and authorization-code calls;
upstream never needed them, and what they do on this watch is not known.

**Unpairing**: there is no bond to drop.

**Recovery**: close the GloryFitPro app, or turn Bluetooth off on the phone
that normally talks to the watch, then scan again.

**Host stacks**: upstream built and ran its client on macOS (CoreBluetooth,
Apple Silicon). Its README names Linux as a target but reports no Linux run.
See the MTU note under [Troubleshooting](#troubleshooting) before sending
chunked transfers from BlueZ or Android.

## Protocol Summary

### Identification

Scan by the exact name `HT36`. Whether the advertisement carries a service
UUID or manufacturer data is not recorded, so the spec filters on neither.
After connecting, the protocol is confirmed by the `34f1`/`34f2` pair under
`000056ff-0000-1000-8000-00805f9b34fb` and a battery reply.

The GATT table alone is **not** an identification. A GloryFitPro watch sold
as "Stratos 2 Ultra" shows exactly the same table
([Gadgetbridge issue #5541](https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/5541)),
and another GloryFit device writes a different command dialect, frames
starting `eb 02`, to the same `34f1` characteristic
([Gadgetbridge issue #5505](https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/5505)).

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `000056ff-0000-1000-8000-00805f9b34fb` | Command service | Write `000034f1-0000-1000-8000-00805f9b34fb` (write without response); notify `000034f2-0000-1000-8000-00805f9b34fb`. Everything on this page. The service UUID is from the upstream README and its archived nRF Connect table, and matches the sibling watch |
| `000055ff-0000-1000-8000-00805f9b34fb` | Secondary config channel | `000035f1-0000-1000-8000-00805f9b34fb` (read, write), `000035f2-0000-1000-8000-00805f9b34fb` (notify). The single byte `a1` returns the system-version string. Set frames written here take effect, queries get no reply. Upstream's reading of the SDK puts this pair under `0000ffe0-0000-1000-8000-00805f9b34fb` instead, so find it by characteristic UUID |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Model number `2a24`, manufacturer `2a29`, PnP ID `2a50`. Values not recorded |
| `0000ffd0-0000-1000-8000-00805f9b34fb` | Unused | `ffd1` (write), `ffd2` (notify), `ffd3` (write, notify). Writes to `ffd1` get no reply; upstream calls it a decoy |
| `e49a3001-f69a-11e8-8eb2-f2801f1b9fd1` | Firmware update | **Never write `e49a3002-f69a-11e8-8eb2-f2801f1b9fd1`.** Notify `e49a3003-f69a-11e8-8eb2-f2801f1b9fd1`. No bytes documented |
| `e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1` | Secondary data | Write `e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1`, notify `e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1`. Purpose unknown; never written upstream |

A research note in circulation spells the update characteristic as
`0000e49a3002-…` on the 16-bit base. That form is malformed; the
characteristic is `e49a3002-f69a-11e8-8eb2-f2801f1b9fd1`.

### Frame envelope

| Offset | Length | Field | Notes |
|--------|--------|-------|-------|
| 0 | 1 | Prefix | Always `01` |
| 1 | 1 | Group | Command domain (table below) |
| 2 | 1 | Marker | `aa` query, `ab` set, `ac` device push or acknowledgement |
| 3 | 1 | Opcode | |
| 4 | 1 | Length | Payload length. **Absent on bare queries** (`01 a4 aa 16`). In a chunked transfer this byte is the section index, and `fd` marks the trailer |
| 5 | n | Payload | |

- Replies to queries echo the request's four bytes, `aa` marker included,
  then add length and payload.
- Set commands are acknowledged in several forms: vibrate with
  `01 a5 ac 05 01 01`, the health settings with an echo of `01 e1 ab <op>`,
  GPS with an echo of the whole frame.
- Frames the watch sends on its own use marker `ac`.
- Single frames carry no checksum.
- **Set-time (group `a3`) breaks the pattern**: after the group come
  tag-length-value entries, `01 04 <time>` and `10 02 <zone>`.

| Group | Domain |
|-------|--------|
| `a2` / `a3` | Time (older / current SDK form) |
| `a4` | Battery and device information |
| `a5` | Find/vibrate, find state, default configuration |
| `b0` | Notification push (chunked) |
| `b2` | Notification switches (chunked) |
| `c5` | History index |
| `c6` | History data (opcode `01` fitness, `04` sleep) and the spontaneous stream |
| `e0` | Weather push (chunked) |
| `e1` | Health-measurement settings (reference only) |
| `e3` | Watch faces (out of scope) |
| `e8` | Workout history |
| `e9` | GNSS: position push, ephemeris query (file transfers out of scope) |

### Commands

All written to `000034f1-0000-1000-8000-00805f9b34fb`; replies on `34f2`.
Multi-byte numbers are big-endian.

| Command | Bytes | Reply / effect |
|---------|-------|----------------|
| Battery | `01 a4 aa 16` | `01 a4 aa 16 06 01 01 <level> 02 01 <x>`; level in % at byte 7 (`58` = 88 %). Byte 10 unknown, always `00` so far |
| Device info | `01 a4 aa aa` | Chunked reply; see [Device info](#device-info) |
| Find watch | `01 a5 ab 04 01 01` | Physical buzz; acknowledged `01 a5 ac 05 01 01` |
| Find state | `01 a5 aa 07` | `01 a5 aa 07 01 01`. Upstream calls it the wear state after the SDK's name for it; whether it means "on the wrist" or "find function on" is not established |
| Default config | `01 a5 aa 01` | Seven entries `<index> 01 <state>`; meaning unknown |
| GPS position | `01 e9 ab 02 0c <time u32> <lat i32> <lon i32>` | Echoed back. Latitude and longitude are degrees × 10⁷, two's complement. Nothing visible on the watch |
| Ephemeris parameters | `01 e9 aa 01` | Status bytes, then ASCII `f1e1G3;f1e1C3;f1e1E3` |
| Fitness index | `01 c5 aa 01 08 <start u32> <end u32>` | `01 c5 aa 01 01 <count>` |
| Fitness data | `01 c6 aa 01 0a <start u32> <end u32> <frame u16>` | Chunked `01 c6 aa 01 <section> …`, trailer `01 c6 aa 01 fd <xor8>` |
| Sleep history | `01 c6 aa 04 08 <start u32> <end u32>` | Chunked, trailer ends `fd fd <xor8>` |
| Workout history | `01 e8 aa 01 08 <start u32> <end u32>` | Upstream's watch had none: `01 e8 aa 01 00 00 00 00`, then `fd fd` |
| Set time (SDK form) | `01 a3 01 04 <time u32> 10 02 <zone> <fraction>` | **Acknowledged, clock unchanged** (upstream, twice) |
| Set time (older form) | `01 a2 ab 01 06 <time u32> <zone> <fraction>` | Never tried |
| Version string | `a1` (raw, to `000035f1-0000-1000-8000-00805f9b34fb`) | On `35f2`: `a1` then ASCII `AT364D`, `V` and a six-digit build |

Times are seconds since 1970-01-01 as the open client sends them (UTC);
whether the watch stores UTC or local seconds is not established. The
set-time zone byte is sign-magnitude hours: `0x80` plus the hours for UTC+0
and east, the bare hours for west. The fraction byte is minutes past the
hour as hundredths of an hour (UTC+5:30 sends `85 32`).

### Chunked transfers

Upstream calls these "subpackaged". Anything longer than one write travels
as numbered chunks and a trailer, in both directions:

1. Cut the payload into slices of at most 16 bytes.
2. Chunk *n* is `<head hi> <head lo> <flag hi> <flag lo> <n> <slice>`. Head
   is `01` plus the group; flag is the marker/opcode pair.
3. The trailer is `<head> <flag> fd <xor8>`, where `xor8` is the XOR of every
   byte of every chunk frame, headers and section bytes included.
4. Write the frames in order. The open client leaves 150 ms between them
   and does not wait for acknowledgements.

| Head / flag | Carries |
|-------------|---------|
| `01b2` / `abab` | Notification switches |
| `01b0` / `abab` | Notification push |
| `01e0` / `abab` | Weather push |
| `01a4` / `aaaa` | Device-info reply |
| `01c6` / `aa01` | Fitness-history reply |
| `01c6` / `aa04` | Sleep-history reply |
| `01c6` / `ac01` | Spontaneous stream |

The watch acknowledges each chunk and answers the trailer with an `fd`
frame, but upstream published neither layout. One section byte plus the
`fd` marker caps a transfer at 253 chunks (about 4 KB). A 16-byte slice
makes a 21-byte write; see [Troubleshooting](#troubleshooting) for the MTU
consequence.

### Notification push

First write the **notification switches** in the same connection:

```text
01 b2 ab ab 00 ab 01 01 01 ab 02 01 01     chunk: incoming calls on, messages on
01 b2 ab ab fd b0                          trailer
```

Then send the notification body (group `b0`) as chunks. The body is a list
of `<tag 2 bytes> <length 1 byte> <value>` entries, text in UTF-16BE:

| Tag | Field | Value |
|-----|-------|-------|
| `ab01` | App name | UTF-16BE (the open client sends `HT36`) |
| `ab02` | Contact | UTF-16BE |
| `ab03` | Content | UTF-16BE; the watch truncates long text |
| `ab04` | Id | 1 byte, id modulo 255 |
| `ab05` | Phone number | UTF-16BE |
| `ab06` | Source package | UTF-16BE |
| `ab07` | Title | UTF-16BE |
| `ab08` | Type | 1 byte. **Required**: without it the watch acknowledges and shows nothing. Upstream sends `1` |
| `ab09` | Vibrate | 1 byte, `1` or `0`. Always present |
| `ab0a` | Message id | 4 bytes; the SDK sends it only for types 7 and 52 |

Worked example (app `X`, content `Hi`, type 1, vibrate):

```text
01 b0 ab ab 00 ab 01 02 00 58 ab 03 04 00 48 00 69 ab 08 01 01
01 b0 ab ab 01 ab 09 01 01
01 b0 ab ab fd 7d
```

### Weather push

Group `e0`, same chunking. Body entries in this order, numbers big-endian:

| Tag | Field | Value |
|-----|-------|-------|
| `ab02` | Unit | 1 byte: `0` Celsius, `1` Fahrenheit |
| `ab04` | AQI | 2 bytes |
| `ab05` | City | UTF-16BE |
| `ab06` | Current temperature | 2 bytes, signed, whole degrees in the `ab02` unit |
| `ab07` | High | 2 bytes, signed |
| `ab08` | Low | 2 bytes, signed |
| `ab09` | Condition icon | 1 byte; table not mapped (the open client sends `1`) |
| `ab0a` | PM2.5 | 1 byte, µg/m³ |
| `ab0b` | Published time | 4 bytes, Unix seconds |
| `ab0c` | Wind | Byte 0 direction code, byte 1 force level |
| `ab0f` | Humidity, UV | Byte 0 relative humidity %, byte 1 UV index |

The spec's `protocol_details.test_vectors` has a full five-frame example.

### Device info

The reply to `01 a4 aa aa` reassembles into repeated `aa <tag> <len>
<value>` entries:

| Tag | Length | Field |
|-----|--------|-------|
| `01` | 6 | Bluetooth address |
| `02` | 8 | Device type, ASCII (`NAL-WB00`) |
| `03` | 6 | Hardware revision, ASCII digits |
| `08` | 4 | Firmware version, ASCII (`V1.0`) |
| `09` | 4 | UI version, ASCII |
| `0d` | 8 | Model code, ASCII |
| `15` | 13 | System version string, ASCII (same as the `a1` answer) |
| `16` | 6 | Battery block `01 01 <level> 02 01 <x>` |
| `04`, `05`, `0f`, `12` | 1 | Unknown flags |
| `13` | 4 | Unknown version string |
| `14` | 0 | Empty |

### History

**Fitness.** Ask `c5`/`01` for the frame count, then `c6`/`01` for a frame.
Strip `01 c6 aa 01 <section>` from each chunk and concatenate. The result is
`<frame index u16> <start time u32>` followed by per-minute slots:
`<minute offset u16>`, a function mask, then one value per present function.
The mask is one to four little-endian bytes; a byte with its top bit set is
followed by another, and bit *n*−1 set means function *n* is present
(functions 8, 16 and 24 are the continuation bits, not functions).

| Function | Field | Bytes |
|----------|-------|-------|
| 1 | Steps | 1 |
| 2 | Calories (unit not established) | 1 |
| 3 | Distance, m | 2 |
| 4, 5, 6, 7 | Heart rate: resting, max, min, dynamic (bpm) | 1 each |
| 9 | SpO2, % | 1 |
| 12 | Heart rate average, bpm | 1 |
| 17 | Blood pressure: systolic, diastolic (mmHg) | 2 |
| 27 | Blood sugar, raw / 10 | 2 |
| others | See the spec (mood, PAI, HRV, …) | 2 unless listed |

Upstream only requests frame 0. A 24-hour window returned 60 per-minute
records, so a full sync probably walks frame indexes up to the count; that
is not verified. Upstream also drops an unexplained leading `00` from some
buffers.

**Sleep.** 7-byte records: `<start u32> <minutes u16> <stage>`, stage 1 deep,
2 light, 3 REM, 4 awake, 7 and 8 session markers with 0 minutes. A single
night decodes cleanly upstream. Multi-night pulls come out misaligned. This
project's guess, unverified: sleep and workout replies use a **two-byte**
section index (they end `fd fd`, and the empty workout reply is
`01 e8 aa 01 00 00 00 00`), so stripping five bytes per frame leaves one
stray byte per continuation frame.

### The spontaneous stream

About every 10 s the watch sends a 16-byte frame
`01 c6 ac 01 00 0a <time u32> b8 08 <4 bytes>` and a 6-byte
`01 c6 ac 01 fd <xor8>`. The second is the chunk trailer of the first:
upstream confirmed its last byte is the XOR of the 16-byte frame in four of
four complete pairs. Upstream ignores both.

This project's reading, **unverified**: the time field is a Unix timestamp
(the capture decodes to the minute it was taken), and `b8 08` is a function
mask in the fitness-history encoding meaning resting, maximum, minimum and
average heart rate, followed by four one-byte values (73–86 in the capture).
If that holds, the watch *does* push live heart rate, contrary to upstream's
conclusion that it does not.

### Watch faces

Described so a file can be recognised; no upload bytes. The 24-byte
little-endian header holds a dial id of `0x0005a871` (bytes `71 a8 05 00`,
upstream's "magic"), the data size, a CRC-32 of everything after the header,
width and height (240 × 240), and two compression words. 24-byte element
records follow, ending in a `u16` of 0, then the pixel data: RGB565 stored
byte-swapped, with a per-row run-length codec for element types 4–42, 47, 48
and 71. Upstream's codec is a port of the open editor
[janaboy74/wfeditormk66](https://github.com/janaboy74/wfeditormk66). The
watch reported a 409,600-byte face slot and held nine faces, its maximum;
the upload is refused at that point, and no delete command is known.

### Firmware update

The watch has an update service, `e49a3001-f69a-11e8-8eb2-f2801f1b9fd1`.
Its write characteristic `e49a3002-f69a-11e8-8eb2-f2801f1b9fd1` is the one
thing upstream says can brick the watch, and no client should write it. The
vendor app checks the vendor's web service for a newer build; upstream
replicated that check and got "no new version" for every build number it
tried, so no firmware image for this watch is publicly obtainable. The
update stack is not identified. See
[Firmware Update](../protocols/firmware-update.md).

## Troubleshooting

These come from upstream's notes and code.

- **A notification push is acknowledged but nothing appears.**
  - The notification switches (`01 b2 …`) were not written earlier in this
    connection.
  - The `ab08` type tag is missing.
- **Set-time is acknowledged but the clock does not change.** Reported
  upstream after two tries; the format this firmware wants is not matched.
  The older `a2` form has not been tried. Until then the vendor app sets the
  clock.
- **Nothing arrives on `34f2` after subscribing.** Normal for about 19 s;
  write a battery query for an immediate answer. If that gets nothing, the
  vendor app is probably holding the watch.
- **Writes to `ffd1` get no reply; queries written to `35f1` get no reply.**
  Wrong channel. Use `000034f1-0000-1000-8000-00805f9b34fb`.
- **Chunk writes fail or are truncated on Linux or Android but work on
  macOS.** A 16-byte slice makes a 21-byte write, one more than a default
  23-byte ATT MTU allows. CoreBluetooth negotiates a larger MTU on its own;
  elsewhere, request one. Smaller slices (the SDK's file transfers use 15
  bytes) may work, but that is not established for these pushes.
- **Decoded device info has no model string or battery.** The open client's
  decoder keys its labels by the decimal numbers 15 and 16 (`0x0f`, `0x10`).
  The watch sends the model string as tag `0x15` and the battery block as
  `0x16`, as upstream's own decode log shows.
- **A multi-night sleep pull decodes to nonsense.** A known upstream limit;
  see [History](#history) for a likely cause.
- **Heart-rate or SpO2 measurement commands are acknowledged but no reading
  arrives.** Upstream tried every trigger for 90 s worn: results are not
  pushed. Read the values from fitness history (and see
  [the spontaneous stream](#the-spontaneous-stream)).
- **The watch freezes after an experiment.** Upstream suggests holding the
  button for 10–15 s or letting the battery drain; unconfirmed on this
  model.
- **A watch-face upload is refused as "too many faces".** The slots are
  full, and the reorder command reorders without deleting. Out of scope
  here.

## Open questions

- The set-time frame this firmware accepts.
- Whether notification and weather chunks sliced smaller than 16 bytes
  reassemble.
- The layout of the chunk acknowledgements and of the `fd` answer, and
  whether a wrong XOR is rejected.
- Whether the spontaneous `01 c6 ac 01` frames are live heart rate.
- Whether sleep and workout replies use a two-byte section index.
- How many fitness frames a window holds, and whether frame indexes past 0
  return the rest.
- Whether history timestamps are UTC or local.
- The notification type values other than 1, and the weather icon and wind
  code tables.
- What the find-state query and the seven default-config entries mean; how
  long the find buzz lasts and whether value 0 stops it.
- Whether the advertisement carries a service UUID, and whether the address
  is public.
- Whether the watch accepts more than one central at a time.
- The SoC, and so the update stack.
- What the `e49a25f8` and `ffd0` services are for.
- Any factory-reset route, and what it clears.

## Tools Used

- [x] Reading of the open client tcsenpai/ht36 (source, wiki, archived notes, feature table) at commit `cbcfc4aa8cc031f84e844bfe1d786987b5e1890a`
- [x] Cross-check of the GATT table against Gadgetbridge issue #5541
- [x] Search of three public Gadgetbridge captures of other GloryFit-app devices for this protocol's frames (none found; they speak the `eb 02` dialect)
- [x] Python-stdlib transcription of the chunk, TLV and GPS rules to produce the spec's test vectors
- [ ] nRF Connect dump of the advertisement and an HCI capture of the vendor app setting the time and pushing a notification: **still needed**

## References

- [tcsenpai/ht36](https://github.com/tcsenpai/ht36): the open client this spec is built from (MIT)
- [tcsenpai/ht36: src/proto.ts](https://github.com/tcsenpai/ht36/blob/cbcfc4aa8cc031f84e844bfe1d786987b5e1890a/src/proto.ts): frame builders and decoders
- [tcsenpai/ht36: src/fitness.ts](https://github.com/tcsenpai/ht36/blob/cbcfc4aa8cc031f84e844bfe1d786987b5e1890a/src/fitness.ts): history decoders
- [tcsenpai/ht36: src/face.ts](https://github.com/tcsenpai/ht36/blob/cbcfc4aa8cc031f84e844bfe1d786987b5e1890a/src/face.ts): watch-face codec
- [tcsenpai/ht36 wiki: command table](https://github.com/tcsenpai/ht36/blob/cbcfc4aa8cc031f84e844bfe1d786987b5e1890a/wiki/commands.md)
- [Gadgetbridge issue #5541](https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/5541): the same GATT table on a sibling GloryFitPro watch
- [Gadgetbridge issue #5505](https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/5505): a GloryFit device with a different dialect on `34f1`
- [janaboy74/wfeditormk66](https://github.com/janaboy74/wfeditormk66): open watch-face editor for this `.bin` format
- [GloryFitPro on Google Play](https://play.google.com/store/apps/details?id=com.yc.gloryfitpro)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update (DFU / OTA)](../protocols/firmware-update.md)

## Contributors

- Claude Code agent: spec written from the open-source client and its notes (no hardware, no capture)
