# Baofeng UV-5R family — serial programming and its band limits

## Target metadata
- target_id: baofeng-uv5r-family
- app package_id(s): TBD (no vendor mobile app; the manufacturer ships a
  Windows CPS, and third-party open-source tools cover the protocol)
- device class: handheld VHF/UHF transceiver
- transport(s): USB serial over a K-plug cable, 9600 baud
- local-only viability: **high**. Cable, flat memory image, no network.

Members: the UV-5R itself and the radios that program like it — BF-F8HP,
UV-82, GT-5R, and the AR-152, which is reported to program as a BF-F8HP. The
GMRS UV-5G is built on the UV-5R but answers an ident the published driver
refuses, and it is not covered here.

This is the *older* family. It is not the UV-17Pro protocol and shares none of
its framing. Documented here because it is the family with a software transmit
range, and the one a cable, rather than the radio's own Bluetooth, programs.

## Known facts (public + observed)
Derived from CHIRP's published driver. Nothing here has been read off a radio
by this project — every value below is what the driver does, precise enough
to implement from, and unconfirmed until the evidence checklist says
otherwise.

- **Session**: 9600 baud, 8N1, and nothing is scrambled. The host sends a
  seven-byte magic **one byte at a time**, about ten milliseconds apart;
  a radio that recognises it answers a single 0x06 and ignores the rest. The
  magic depends on the model and its firmware, so a host tries each
  candidate for the model in turn:

  | Magic | Tried for |
  | --- | --- |
  | `50 BB FF 20 12 07 25` | the UV-5R (newer firmware) and the BF-F8HP |
  | `50 BB FF 01 25 98 4D` | the UV-5R (original firmware) |
  | `50 BB FF 20 13 01 05` | the UV-82 |
  | `50 BB FF 20 14 04 13` | the BF-F8HP |

  The host then sends 0x02, and the radio answers with its ident: eight
  bytes ending 0xDD, or twelve on some UV-6s, whose bytes 1, 2, 4 and 6 are
  padding around the same eight. One more 0x06 each way and the radio
  accepts block commands.
- **The ident names the variant.** Its fourth byte is 0x02 on the 220 MHz
  variant, whose upper band is not the one the rest of this document
  describes; an implementation should refuse it rather than write it as a
  UV-5R. The GMRS UV-5G answers an ident the driver refuses as well, and its
  memory is not described here.
- **Reads**: `S` (0x53), a 16-bit big-endian address and a length. The radio
  answers `X` (0x58), the same address and length, then the data. The host
  acknowledges each answer with 0x06 — and the radio answers *that* with a
  0x06 of its own, so **every answer after the first arrives behind a stray
  0x06**. A reader that takes it for the start of the next answer is out of
  step for the rest of the session. Reads are 0x40 bytes.
- **Writes**: `X`, the address, 0x10 and sixteen bytes of data, acknowledged
  with 0x06. Writes are sixteen bytes, on sixteen-byte boundaries — smaller
  than the reads, so a changed byte costs one sixteen-byte write, not a 0x40
  one.
- **Before anything else, three probe reads**, in this order:
  1. 0x1E80, whose answer is thrown away. Newer radios answer a read of the
     auxiliary block made cold with the wrong data; one read outside it
     first fixes that.
  2. 0x1EC0, which carries the firmware version string at 0x1EF0 (fourteen
     bytes, padded). The firmware decides the band-limit layout below.
  3. 0x1FC0, a full 0x40 read, to learn whether this radio **drops a byte**
     from it: some do, which shows as 0xFF at offset 15 of the answer, every
     later byte moved up a place. On those radios, 0x1FC0 onwards is read
     sixteen bytes at a time.
- **Memory**: main memory 0x0000–0x1800, and an auxiliary block
  0x1EC0–0x2000. A saved image is conventionally the eight ident bytes, then
  main, then aux: 0x1948 bytes. (0x1808 is the ident and main memory alone.)
  The ident goes first so a write can check the image is going back to the
  same kind of radio.
- **Channels**: 128 records of sixteen bytes from 0x0000.
  - `0..3` receive and `4..7` transmit frequency, little-endian BCD in units
    of ten hertz. A transmit field of all 0xFF means receive only.
  - `8..9` receive tone and `10..11` transmit tone, little-endian 16-bit, in
    the same encoding as the newer family
    ([baofeng-uv17pro-family.md](baofeng-uv17pro-family.md)): CTCSS in
    tenths of a hertz at or above 0x0258, a one-based index into the DCS
    table below it.
  - `12`: signal code in the low nibble.
  - `14`: power in the low two bits — 0 high, 1 low on a two-level radio;
    0 high, 1 mid, 2 low on a three-level one such as the BF-F8HP.
  - `15`: bit 6 set for **wide**, bit 2 set for in-scan, bit 3 busy-channel
    lockout, bits 0–1 PTT-ID. Note the bandwidth bit reads the opposite way
    to the newer family's.
  - A record whose first byte is 0xFF is an empty slot.
- **Names** live apart from the records: sixteen bytes per slot from 0x1000,
  of which the first **seven** are the name, padded with 0xFF. The display
  has capital letters, digits, the space and a handful of punctuation marks;
  anything else is written as a space.
- **Never written**: 0x0CF0–0x0D00 and 0x0DF0–0x0E00 in main memory. Upload
  tools skip them, and an implementation should refuse a change there rather
  than send it. In the aux block only settings ranges are written, and which
  ones depends on the layout: 0x1EE0–0x1EF0 and 0x1FC0–0x1FE0 on the older
  layout; 0x1EE0–0x1EF0, 0x1F60–0x1F70, 0x1F80–0x1F90 and 0x1FC0–0x1FD0 on
  the newer.
- **Band limits exist here, and are editable.** Per band, a five-byte field:
  an enable byte (non-zero: transmitting in the band is allowed), then the
  lower and the upper limit in whole megahertz, each two bytes of big-endian
  BCD — so 136 is `01 36`. Where the fields sit depends on the firmware:

  | Layout | Used by | VHF field | UHF field |
  | --- | --- | --- | --- |
  | Older | firmware `BFB` + a number below 291 | 0x1FCA | 0x1FDA |
  | Newer | everything else, and always the BF-F8HP | 0x1FC0 | 0x1FC5 |

  A firmware string with `BFB` and no readable number after it should stop a
  limit write, not guess a layout: the layout decides which bytes change.
  These fields are what a "MARS/CAP modification done in software" actually
  edits, and ordinary programming tools expose them. Whether the radio
  treats the upper megahertz as allowed — 174 meaning up to 174.995 or only
  174.000 — is not established.

## Device discovery signals
- USB: a K-plug cable presenting a generic USB-serial bridge. Common bridge
  chips are the usual CH340/CP210x/PL2303 family, and counterfeit PL2303
  clones are a well-known source of "the cable does not work on this OS"
  reports. The bridge identifies the cable, not the radio.
- No BLE. No network presence of any kind. Radios in this family that are
  programmed over Bluetooth do it through a separate dongle — see
  [radio-bt-programming-adapters.md](radio-bt-programming-adapters.md).

## Threat model + guardrails
- Scope: only radios the operator owns.
- Writing is destructive if it goes wrong. Read and store the existing image
  first; offer to restore it.
- **On the transmit-range fields, and a departure from a sibling target.**
  [ifreqtech-speaker-mic.md](ifreqtech-speaker-mic.md) sets an explicit
  non-goal: *"will NOT implement any functionality that modifies the radio's
  frequency, power, or other regulated parameters."* That is the right rule
  for the device it was written about — a Bluetooth speaker-mic, where the
  only way to touch a regulated parameter is by accident, and the hazard is a
  PTT bridge keying a transmitter nobody is holding.
  It is the wrong rule for a programmable transceiver. Setting frequencies is
  what programming software is *for*; a tool that refused to write a frequency
  would not be a tool. So this target documents the band-limit fields as
  facts, on the same footing as every other field, and records the reasoning
  rather than leaving a reader to find two documents that appear to
  contradict each other.
  What follows from that, for anything built on this:
  - Widening a transmit range is legal to *configure*. Transmitting outside
    one's own licence or authorization is not, and that is the operator's
    responsibility alone — MARS or CAP membership, or another lawful
    authority.
  - The expanded ranges reach spectrum allocated to public safety, commercial
    and government users. A tool should say so, in those words, before it
    offers the option.
  - It should be off by default, offered only where the fields actually
    exist (they do not exist in the UV-17Pro family at all), and paired with
    a way back to the factory values.
  - None of this is about evading anything. These fields are written by every
    mainstream programming tool including the manufacturer's; documenting
    them defeats no protection and hides nothing that is not already public.

## First experiments (do these first)
1. Identify the cable's bridge chip and confirm the host enumerates it.
2. Send the magic at 9600 baud, ask for the ident, and record it — with the
   firmware string the second probe read returns, which decides the
   band-limit layout.
3. Read the full image and confirm its length.
4. Cross-check the decode of the first twenty channels against an independent
   tool, field by field.
5. Read the band-limit fields at the addresses above for the radio's
   layout, record the values, and check them against an independent tool's
   settings view. **Read them before writing anything** — the factory values
   are what a restore puts back.
6. Write one channel to an unused slot, read it back, restore the backup.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: none.
- Session state machine: magic → ident → probe reads → block reads and
  writes → the link is closed. A dropped link ends the session, so each
  operation starts from the magic again.
- Commands: `S` read, `X` write; no others.
- Payload encoding: cleartext blocks; channel records and names in separate
  regions.
- Timing constraints: the magic's bytes are paced, and this family is widely
  reported to be sensitive to inter-block timing on some cables. Worth
  measuring rather than assuming: ten milliseconds between magic bytes is
  what the published driver waits, not a measured minimum.

## Control surface inventory (what the replacement app must support)
- Onboarding: identify the cable, pick the model, warn about counterfeit
  bridge chips.
- Core: read, decode, edit, encode, write, restore.
- Band limits: read, display, optionally widen, and always restore — behind
  the acknowledgement described above. "Restore" needs the values read
  before the first widening kept somewhere: a radio read after it has been
  widened holds only the widened ones, and a radio of this family cannot be
  told from another of its model, so the values belong with the model.
- Writes: only the sixteen-byte blocks that changed, checked afterwards by
  reading them back — a radio can acknowledge a write it did not keep.
- Error handling: a refused write leaves the radio inconsistent; say so and
  point at the backup.

## Evidence checklist
- [ ] Cable enumerated; bridge chip identified
- [ ] Ident acknowledged; firmware generation recorded
- [ ] Full read of the expected length
- [ ] Decode cross-checked against an independent tool
- [ ] Band-limit fields located and their factory values recorded
- [ ] One channel written, read back, and the backup restored
- [ ] Inter-block timing sensitivity measured

## Spec output (clean-room)
Deferred, for the same reason as the newer family: the device-spec schema has
no vocabulary for a memory image.

## References (URLs only)
- https://chirpmyradio.com/projects/chirp/repository/github/revisions/master/entry/chirp/drivers/uv5r.py
- https://chirpmyradio.com/issues/9755
- https://chirpmyradio.com/projects/chirp/wiki/Baofeng_UV5R
