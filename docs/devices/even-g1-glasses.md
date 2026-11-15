# Even Realities G1 Smart Glasses

> **Status**: Spec Available (from the vendor's open-source demo and community research; no capture, not run against hardware by this project)
> **Protocol**: BLE, two peripherals (one per temple), each a Nordic UART service
> **Manufacturer**: Even Realities
> **Manufacturer Status**: Active. Direct sales ended on 2026-09-15; security support is promised until at least 2029-06-25

## Overview

The Even Realities G1 is a pair of prescription-capable smart glasses. Each
lens has a monochrome green waveguide display, and each temple tip has a
TouchBar. There are microphones, and an ambient light sensor on the right
temple. The phone app shows notifications, a head-up dashboard, text,
navigation, a teleprompter, and captures voice notes ("QuickNote") and
voice questions ("Even AI").

Three facts shape any client:

1. **The glasses are two BLE devices.** Each temple advertises, connects,
   bonds and takes commands on its own. The right temple is the master. A
   client pairs the two advertisements by the channel number in their names
   and drives both.
2. **Display content is not relayed between the temples.** Text, images,
   navigation cards and dashboard content must be written to both, and
   some flows want the left done before the right.
3. **The link must be kept busy.** If nothing is sent for about 30 seconds,
   the glasses drop the connection and show a disconnected icon, so every
   client runs a heartbeat on both temples.

Even Realities publishes part of the protocol in its own open-source demo app
([EvenDemoApp](https://github.com/even-realities/EvenDemoApp), BSD-2-Clause):
TouchBar events, the microphone, text and BMP images. The rest comes from
community work. The largest source is
[Cheddies1/even-g1-companion](https://github.com/Cheddies1/even-g1-companion),
built from that author's captures of the official app on firmware 1.6.6 and
from notes on a third-party firmware decompilation. Gadgetbridge and
emingenc/even_glasses fill in further commands. Upstream labels some findings
"Confirmed"; those are the upstream author's observations, not ours. This
page and the spec mark everything as *reported*.

Out of scope: firmware and OTA update (the opcode exists and is deliberately
not documented), the vendor's cloud AI features, and the Even G2 and later
models.

The machine-readable version is
[`device-specs/devices/even-g1-glasses.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/even-g1-glasses.yaml).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Even G1 (glasses) with the G1 charging case. The device-info reply carries a frame-style letter, A or B |
| Chipset | Probably a Nordic nRF53-class dual-core part (upstream firmware notes describe an application core plus a network core running Nordic sample code). Not confirmed by a teardown |
| Radio | BLE. Each temple exposes a Nordic UART service; the two temples also share a private radio link |
| Display | 488 px wide text area, 5 lines per screen in text mode; BMP images 576 × 136, 1 bit per pixel |
| Inputs | TouchBar on each temple tip (tap, double, triple, long press), head-tilt detection, wear sensor, microphones (the right temple streams audio) |
| Power | Built-in batteries in each temple (about 1.5 days, 2–3 h to charge per the vendor FAQ); the charging case has its own battery and a USB-C port |
| FCC ID | 2BFKR-G1 (glasses), 2BFKR-G1CASE (charging case). [User-manual exhibit](https://fccid.co/api/files/s1/2bfkr_g1_usersmanual_7414235_b7aa1f648c.pdf) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No provisioning: no Wi-Fi, account or key exchange on the wire. A new unit must be activated once in the case, and each temple must be bonded |
| Method | `ble_direct` |
| Advertised name | `G1_<channel>_L_<id>` and `G1_<channel>_R_<id>`, possibly with an `Even ` prefix (Gadgetbridge matches `Even G1_…`). `<id>` is per unit |
| Passphrase protection | not_applicable |
| Confidence | medium (vendor documentation plus three public implementations, none replayed here) |

1. **Activate (first use only).** Fold the left temple first, put the glasses
   in the charging case and connect the case to power for 5–10 seconds. A
   flashing orange case light means the glasses are not seated properly.
2. **Free the temples.** Close the Even Realities app on any phone that was
   driving them, since it holds both links.
3. **Scan and pair up.** Match names against
   `^(Even )?G1_[0-9]+_[LR]_[0-9A-Za-z]+$`. Split on `_`: the field after the
   model is the channel, the next is the side. Offer a pair once a left and a
   right with the same channel are both seen.
4. **Per temple:** connect, discover services, enable notifications on
   `6e400003-b5a3-f393-e0a9-e50e24dcca9e`, request ATT MTU 251, then bond
   (Just Works) if no bond exists yet.
5. **Heartbeat.** Start `25 06 00 <seq> 04 <seq>` on each temple straight
   away and keep it at no more than 8 seconds apart.

Whether glasses that were never set up with the official app will accept a
third-party client is **not established**: every public client ran on glasses
the vendor app had already onboarded.

**Factory reset**: not documented anywhere we looked. The vendor documents a
**soft restart**: tap the left TouchBar five times quickly, then the right
TouchBar five times, and the glasses restart in about 10 seconds. The app also
has Settings → Reset Options → Quick Restart. Neither is stated to clear
pairing, notes or settings.

**Rebinding to a new phone**: in place. In the vendor app use My G1 → Device
Info → Unpair G1, forget both temples in the old phone's Bluetooth settings,
then pair from the new client.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes (medium confidence; see below) |
| Security mode | `just_works` (no PIN or passkey appears in any source) |
| Bonding | `required`, one bond per temple |
| PIN source | none |
| One central at a time | Unknown |
| One bond at a time | Unknown |
| Confidence | medium |

Every public client bonds each temple after the MTU exchange: the vendor
demo on Android, the Cheddies1 companion and Gadgetbridge. The companion's own
code notes that writes fail silently when bonding fails, which suggests the
UART characteristics need an encrypted link. The vendor's troubleshooting
also treats the phone's stored bond as part of the connection. No source
shows the glasses actually refusing an unbonded write, so "required" rests on
that consistent practice.

**Entering pairing mode**: nothing to do. Once activated and out of the case,
each temple advertises whenever no central holds it.

**Unpairing**: unpair in the vendor app (My G1 → Device Info → Unpair G1),
then forget both temples in the phone's Bluetooth settings. Gadgetbridge
names a dedicated unpair opcode (`0x47`) that no other source describes.

**Recovery**: force-stop the vendor app or turn Bluetooth off on the phone
that runs it, then reconnect. If that fails, use the soft restart. Remember
it is two links: a client can end up bonded to one temple and not the other.

## Protocol Summary

### BLE Services

The same service is present on both temples.

| UUID | Name | Description |
|------|------|-------------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART service | Carries every command and event |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | UART write | Host → glasses. Public clients write with response, one write in flight per temple |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | UART notify | Glasses → host: replies, events, audio. Enable its CCCD (`00002902-0000-1000-8000-00805f9b34fb`) |

### Frame rules

- **Byte 0 is the opcode**, in both directions. There is no checksum and no
  trailer.
- **Some families carry a length.** In 0x06, 0x08, 0x0A, 0x1E, 0x21, 0x22,
  0x25, 0x26, 0x39, 0x50 and 0x52, bytes 1–2 are the *total* frame length,
  uint16 little-endian. The firmware drops a frame with a wrong length and
  says nothing. Byte 3 is then a host-chosen sequence number and byte 4 a
  sub-command. The other opcodes (0x01, 0x0E, 0x15, 0x16, 0x18, 0x4B, 0x4E and
  so on) have no length field.
- **Replies** echo the opcode and usually put a status at byte 1: `0xC9`
  success, `0xCA` failure, `0xCB` "chunk accepted, send the next".
- **Size**: stay at or under about 180–194 payload bytes per frame. MTU 251
  is what every client negotiates.

### Which temple gets what

| Send to | Opcodes |
|---------|---------|
| Both, **left first, right after the left answers** | `0x4E` text, `0x18` exit, `0x25` heartbeat |
| Both, independently or in parallel | `0x15/0x20/0x16` BMP, `0x52/0x53` streaming text, `0x06` dashboard, `0x1E` note slots, `0x01` brightness, `0x03` silent mode, `0x08` head-up action, `0x26` double-tap, `0x27` wear detection |
| Both, **interleaved frame by frame** | `0x0A` navigation (right, 10 ms, left, 20 ms, pause 50 ms every 10 pairs) |
| Right only | `0x0E` microphone, `0x1E` QuickNote audio request/ack, `0x0B/0x32` head-up angle, `0x50` dashboard lock (the left rejects it) |
| Left only | `0x4B` notifications, `0x04` notification app whitelist |

Events come from both temples. Microphone audio, QuickNote frames and
head-up events have been seen from the right.

### Commands

All from public sources, not replayed here. `<seq>` is a host counter unless
noted.

| Command | Bytes | Reply / notes |
|---------|-------|---------------|
| Heartbeat | `25 06 00 <seq> 04 <seq>` | `25 …` with `04` at byte 4 |
| Exit to dashboard | `18` | `18 C9` |
| Brightness | `01 <level 0–42> <auto 0/1>` | Then `F5 12 <level applied>` |
| Brightness read | `29` | `29 65 <level> <auto>` |
| Silent mode on / off | `03 0C` / `03 0A` | Triple tap toggles the same state |
| Wear detection | `27 <0/1>` | |
| Head-up angle | `0B <0–60°> 01` | Right temple; read with `32` |
| Head-up behaviour | `08 06 00 <seq> 03 <00 dashboard / 02 no overlay>` | Persisted on the glasses |
| Double-tap action | `26 06 00 <seq> 05 <action>` | 00 none, 02 translate, 03 teleprompter, 04 dashboard, 05 transcribe |
| Device info | `2C <01 Android / 02 iOS>` | Byte 1 frame style `A`/`B`, byte 2 battery % |
| Glasses serial | `34` | Bytes 2–17 are ASCII (per unit, do not publish) |
| Per-lens status | `39 04 00 00` | 6 bytes; byte 5: `00` idle, screen id, or `FF` bad length |
| Microphone | `0E <0/1>` | Right temple; `0E C9 <state>` or `0E CA <state>` |
| Text chunk | `4E <seq> <total> <index> <status> <pos_hi> <pos_lo> <page> <pages> <utf8…>` | See below |
| BMP first chunk | `15 00 00 1C 00 00 <194 bytes>` | No reply per chunk |
| BMP chunk | `15 <index> <≤194 bytes>` | |
| BMP end | `20 0D 0E` | `20 C9` |
| BMP CRC / show | `16 <crc32, big-endian>` | `16 <crc> C9` |
| Dashboard lock | `50 06 00 00 01 01` | Right temple only |
| Streaming text init | `52 06 00 00 01 01` | After the dashboard lock |
| Streaming text line | `52 <len LE> <seq> 02 02 00 <line> 00 <flags> 00 00 <utf8> 0A` | Line 1 = lone LF marker, line 2 = visible text |
| Streaming keep-alive | `53` | Every 5 s |
| Navigation control | `0A 06 00 <seq> <00 init / 04 sync / 05 exit / 06 arrived> 01` | No positive ack |
| Navigation card | `0A <len LE> <seq> 01 <dir> <x LE> <y LE> <5 NUL-terminated strings>` | Remaining time, remaining distance, road, turn distance, speed |
| Dashboard layout | `06 07 00 <seq> 06 <mode> <pane>` | |
| Clock + weather | `06 15 00 <seq> 01 <secs u32 LE> <ms i64 LE> <icon> <temp °C> <unit> <12/24h>` | Local time encoded as if UTC |
| Quick-note slot | `1E <len LE> <seq> 03 01 00 01 00 <slot 1–4> 01 <tlen> <title> <blen LE> <body>` | An empty body deletes the slot |
| QuickNote audio request | `1E 06 00 <seq> 02 <slot>` | Right temple |
| QuickNote audio ack | `1E 06 00 <seq> 04 01` | Glasses answer `1E 06 00 <seq> 04 00` |
| Notification | `4B <msg_id> <total> <index> <≤176 bytes JSON>` | Left temple; `{"ncs_notification": {…}}` |

#### Text (`0x4E`)

Byte 4 is a status: low nibble `1` = new content, high nibble = mode. `0x71`
is plain text; `0x31`–`0x61` are the vendor's Even AI states. Split the UTF-8
into chunks of at most 176 bytes, all with the same `seq`, and send them to the
left temple, then to the right. Every chunk but the last gets `CB`, the last
gets `C9`. The right temple later sends `4E C9 <seq> <total> <last index>` when
it has finished. The vendor wraps to 488 px, font 21, 5 lines per screen. The
byte order of the character position (bytes 5–6) is disputed: the vendor puts
the high byte first. Everyone sends 0.

#### BMP images

Send the **whole .bmp file**, header included: 1 bit per pixel, 576 wide.
Split it into 194-byte chunks, put the storage address `00 1C 00 00` in the
first chunk only, then send `20 0D 0E` and wait for `20 C9`. Last, send
CRC-32/XZ (the zlib CRC) computed over `00 1C 00 00` + the file,
**big-endian**. Both temples can be sent to at the same time. `18` removes
the image.

#### Navigation (`0x0A`)

The official app sends the dashboard lock, then INIT, SYNC, the card, 13
direction-icon bands, 90 route-map slices and SYNC, then SYNC every second
for the whole session. The glasses will not draw a card that arrives without
the images. The icon is 136 × 136, two 1-bit layers, run-length coded as
`<count><byte>` pairs. The map area is 488 × 136. String limits including the
NUL: 24, 24, 64, 24 and 24 bytes. A string over its limit makes the glasses
reject the whole card.

#### Voice: Even AI and QuickNote

- **Left long-press**: `F5 17` → host sends `0E 01` to the right → audio
  arrives as `F1 <seq> <200 bytes LC3>`, exactly 202 bytes per frame → `F5 18`
  on release → `0E 00`. Maximum 30 s.
- **Right long-press** (works even while disconnected): the glasses record
  and store the note, then send `0x21` on release (15-byte "this note" or
  42-byte "all notes" form). The host must ask for the audio with
  `1E 06 00 <seq> 02 <slot>`; it is never sent unprompted. Chunks arrive as
  `1E C8 00 …` (10-byte header, 190 bytes of audio), and the stream ends with
  a short `0x1E` control frame.
- **Decoding**: LC3, 16 kHz mono, **200-byte frames**. For QuickNote, join
  the audio bytes of all chunks first, then cut the result into 200-byte
  frames. Cutting at the 190-byte chunk edges produces clicks.

### Events (`0xF5`)

`F5 <code> [value]`, from either temple. Labels are upstream's; none is
confirmed by this project.

| Code | Meaning | Upstream status |
|------|---------|-----------------|
| `00` | Double tap closed a feature / went home | confirmed upstream |
| `01` | Single tap (vendor README) | **not** forwarded on 1.6.6: single taps stay on the glasses |
| `02` / `03` | Head up / head back down | confirmed upstream |
| `04` / `05` | Silent mode on / off (triple tap) | confirmed upstream |
| `06` / `07` | Worn / not worn | confirmed upstream |
| `08` / `0B` | In case, lid open / lid closed | confirmed upstream |
| `09` | Charging state flag | suspected |
| `0A <pct>` | Glasses battery (every 1–2 s while worn) | confirmed upstream; 94–100 % is synthesised by the firmware |
| `0E <flag>` | Case cable state | suspected |
| `0F <pct>` | Case battery | confirmed upstream |
| `12 <level>` | Brightness actually applied | confirmed upstream (Gadgetbridge calls `12` a long press) |
| `17` / `18` | Left long-press start / release | vendor README; `18` confirmed upstream |
| `1E` / `1F` | Dashboard opened / closed follow-ons | suspected |
| `20` | Double tap with a host-handled action configured (arrives 1–6 s late) | confirmed upstream |

### Readbacks

`0x29`–`0x3F` are readbacks. The useful ones: `29` brightness, `2C` device info
and battery, `32` head-up angle, `33`/`34` serials, `35` the channel the
temples share, `36` notification counts, `39` per-lens screen state (the only
way to check that a lens really shows what you sent). Several others are
named in the spec's `protocol_details.readbacks`.

### Firmware update

Out of scope. The glasses update through the vendor app, and the case has a
desktop updater. The opcode that starts an update is deliberately left out of
the spec. See [Firmware Update](../protocols/firmware-update.md) for why this
catalogue treats update paths with care.

## Troubleshooting

- **Only one temple shows up in a scan.** The other is still held by the
  vendor app on some phone, or the glasses are asleep in a closed case or
  were never activated.
- **The write succeeds but nothing appears.** For the length-bearing
  families, check bytes 1–2: a wrong total length is dropped without a word.
  Check you wrote to both temples, since display content is not relayed.
  For navigation, send the icon and map images as well as the card.
- **The two lenses disagree** (for example, different notification counts).
  One temple reconnected first and got content alone; the vendor lists this
  as known issue 014. After any reconnect, resend the current content to
  both temples.
- **The link drops about every 30 seconds.** No heartbeat. Send one to each
  temple at least every 8 seconds; Android can add sleep time on top of your
  timer.
- **QuickNote audio clicks.** The LC3 frames were cut at chunk boundaries;
  join the payloads first, then cut every 200 bytes.
- **Single taps do nothing in a third-party app.** Expected: firmware 1.6.6
  handles single taps on the glasses and does not report them. Use double
  tap (`F5 20` with a host-handled double-tap action) or head-up events.
- **Things to leave alone.** The firmware-update opcode, and the firmware's
  test mode (which unlocks a raw-PCM microphone). Neither is documented here.

## Tools Used

- [x] Vendor documentation: EvenDemoApp README and connection-flow doc, the Even Realities help centre, the Quick Guide and the FCC user-manual exhibit
- [x] Community research: Cheddies1/even-g1-companion protocol reference, event mapping and firmware-decompilation notes
- [x] Public implementations: EvenDemoApp, the Cheddies1 companion, emingenc/even_glasses, Gadgetbridge
- [ ] HCI capture of the official app (pending hardware)
- [ ] Replay against a real pair (pending hardware)

## References

- [Even G1 Quick Guide (PDF, Even Realities)](https://support.evenrealities.com/hc/article_attachments/15913878793103)
- [G1 user-manual exhibit, FCC ID 2BFKR-G1 (PDF)](https://fccid.co/api/files/s1/2bfkr_g1_usersmanual_7414235_b7aa1f648c.pdf)
- [Even Realities help centre: User guide](https://support.evenrealities.com/hc/en-us/articles/14301335051023-User-guide) ·
  [Resolving Even G1 Connection Issues](https://support.evenrealities.com/hc/en-us/articles/14309516711055-Resolving-Even-G1-Connection-Issues) ·
  [Known Issues](https://support.evenrealities.com/hc/en-us/articles/14309475255183-Known-Issues) ·
  [Sales Discontinuation Notice](https://support.evenrealities.com/hc/en-us/articles/17564427335823-Even-G1-Sales-Discontinuation-Notice)
- [even-realities/EvenDemoApp](https://github.com/even-realities/EvenDemoApp) and its
  [G1 Bluetooth connection flow](https://github.com/even-realities/EvenDemoApp/blob/main/docs/G1_BLE_CONNECTION.en.md)
- [Cheddies1/even-g1-companion](https://github.com/Cheddies1/even-g1-companion):
  [protocol reference](https://github.com/Cheddies1/even-g1-companion/blob/main/docs/protocol-reference.md) ·
  [event mapping](https://github.com/Cheddies1/even-g1-companion/blob/main/docs/even-g1-event-mapping.md) ·
  [firmware decompilation notes](https://github.com/Cheddies1/even-g1-companion/blob/main/docs/firmware-decomp-notes.md)
- [emingenc/even_glasses](https://github.com/emingenc/even_glasses)
- [Gadgetbridge: Even Realities G1 support](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/evenrealities)
- See also [Pairing, Bonding and Unpairing](../protocols/pairing.md) and
  [Common BLE Patterns](../protocols/ble-common.md)

## Contributors

- Initial spec from the vendor demo, the Cheddies1 companion notes and public implementations (2026-09)
