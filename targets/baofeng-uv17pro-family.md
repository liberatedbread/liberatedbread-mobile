# Baofeng UV-17Pro family — serial/BLE codeplug programming

## Target metadata
- target_id: baofeng-uv17pro-family
- app package_id(s): com.aewt.app.friends ("Ola Radio", Baofeng's own wireless
  programming app) — not required for the protocol below, which is spoken by
  open-source software as well
- device class: handheld VHF/UHF transceiver (amateur and GMRS variants)
- transport(s): USB serial over a K-plug cable (115200 baud) / BLE GATT UART on
  the models with a radio of their own — see
  [baofeng-ble-programming.md](baofeng-ble-programming.md)
- local-only viability: **high**. There is no cloud in this picture at all. A
  radio is programmed by a cable or a short-range Bluetooth link, the whole
  memory is a flat image, and a complete, actively-maintained open-source
  implementation exists to check any reading against.

Members: UV-17Pro and UV-17R-Plus, UV-5R Mini, UV-5G Mini / "Mini 5", UV-32,
UV-21Pro, UV-25, BF-F8HP-PRO, K6, and several rebadges (Radioddity GM-30 Plus
and Pro, Baofeng GM-21). They differ in memory extent and in which ident
string they answer to; the framing and the channel record are shared.

## Known facts (public + observed)
Derived from CHIRP's published drivers (see References). None of it has been
read off a radio by this project — that gap is the point of the evidence
checklist below.

- **Session**: the host sends a 16-byte ASCII ident string; the radio answers
  a single 0x06. Three fixed exchanges follow, each with a known reply length:
  `0x46` → 16 bytes, `0x4D` → 15 bytes, then a 25-byte sequence beginning
  `SEND!` → 1 byte. Only then does the radio accept block commands.
- **Ident strings** are per-model, all 16 bytes and all beginning `PROGRAM`.
  The UV-17Pro and UV-17R-Plus answer to one, the Minis and the UV-32 to
  another, and the GMRS, BF-F8HP-PRO and K6 variants each to their own.
- **Framing**: one opcode byte, a 16-bit big-endian address, a one-byte
  length, and — for a write — the payload. `0x52` reads, `0x57` writes. A read
  reply echoes those four header bytes and then returns the payload; a write
  is acknowledged with 0x06.
- **Obfuscation**: block payloads are passed through a rotating four-byte XOR
  before transmission. The key is one of twenty four-byte symbols; every model
  in this family uses the same one. Four exemptions make it its own inverse:
  a key byte of ASCII space is skipped, and so is a data byte of 0x00, 0xFF,
  or one already equal to the key byte or its complement. It is a
  transport-level scramble, not a security control — the table is a constant
  in every implementation that speaks this protocol, and it protects nothing.
- **Memory** is a handful of non-contiguous regions concatenated into one flat
  image: on a UV-5R Mini, 0x8040 bytes from 0x0000, 0x40 from 0x9000 and
  0x1C0 from 0xA000, for 0x8240 total. Larger family members add a fourth
  region and reach 0x8380. **The image offset is not the radio address**, and
  conflating them shifts the whole codeplug.
- **Channel record**: 32 bytes, from the start of the image, one per memory
  slot (999 on the Minis, 1000 on the UV-17Pro).
  - `0..3` receive frequency, `4..7` transmit frequency: little-endian BCD in
    units of ten hertz.
  - `8..9` receive tone, `10..11` transmit tone: little-endian 16-bit. 0 and
    0xFFFF are "no tone". A value at or above 0x0258 is CTCSS in tenths of a
    hertz. Below that it is a **one-based index into a DCS code table**, with
    0x6A added for reverse polarity — so the table's contents and order are
    load-bearing. The table is the 104 standard codes plus 645, sorted.
  - `12` and `13` carry DTMF-related settings; `16..19` are unidentified.
  - `14` packs transmit power in its low two bits (0 is high).
  - `15` packs, among other flags, one bit for bandwidth and one for scan
    membership. **The bandwidth bit is set for NARROW**, which is the
    opposite of how its usual name reads.
  - `20..31` the channel name, twelve characters, padded with 0x00 or 0xFF.
  - A record whose first byte is 0xFF is an empty slot.
  - A transmit frequency field of all 0xFF or all 0x00 means transmit is
    inhibited — the receive-only marker.
- **No adjustable band limits.** There is no lower/upper/enable field group
  anywhere in this family's codeplug. See the guardrail section.

## Device discovery signals
- BLE (the models that have it): see
  [baofeng-ble-programming.md](baofeng-ble-programming.md).
- USB: a K-plug (Kenwood two-pin) cable presenting a generic USB-serial
  bridge. The bridge chip identifies the cable, not the radio; the radio is
  identified by which ident string it answers.
- There is no Wi-Fi, no mDNS and no AP mode. Nothing to discover on a network.

## Threat model + guardrails
- Scope: only radios the operator owns.
- **Writing a codeplug is the one destructive operation here.** A wrong
  address, a wrong length or a wrong obfuscation step leaves a radio holding
  a partly written image. Any implementation must read and store the existing
  image before writing, and offer to put it back.
- **On transmit range, and a departure worth stating plainly.**
  [ifreqtech-speaker-mic.md](ifreqtech-speaker-mic.md) records an explicit
  non-goal: *"will NOT implement any functionality that modifies the radio's
  frequency, power, or other regulated parameters."* That was written about a
  Bluetooth speaker-mic, where the hazard is a PTT bridge keying a
  transmitter the user is not holding, and it is right for that device.
  It is not the right rule for a programmable transceiver, where setting the
  frequency **is** the function: every programming tool in existence, the
  manufacturer's own included, writes the frequency of every channel.
  So this target documents channel programming, deliberately, and treats the
  operator's licence as the operator's business.
  That said, **this family turns out to have no software transmit-range
  unlock to document.** Its transmit limits are not in the codeplug. Widening
  them is not something this protocol can express, and any tool claiming
  otherwise for these models is worth doubting. The older UV-5R serial family
  is different — see
  [baofeng-uv5r-family.md](baofeng-uv5r-family.md), where the fields do
  exist and the guardrail is argued in full.
- Non-goal: nothing about defeating a security control. The byte substitution
  above is a transport quirk, published for a decade, and describing it
  circumvents no protection.

## First experiments (do these first)
1. With a K-plug cable or the radio's own Bluetooth, send the ident string and
   confirm the single 0x06. This alone settles whether the model is in this
   family.
2. Run the three handshake exchanges and confirm each reply length exactly.
   A reply of the wrong length means the two ends are out of step and every
   subsequent read is misaligned.
3. Read one 0x40-byte block from 0x0000, apply the substitution, and look at
   it: bytes 0..3 should be a plausible frequency in little-endian BCD.
4. Read the whole image and confirm the total length matches the region table
   for that model.
5. **Cross-check the decode against an independent tool.** Open the same
   radio in CHIRP and compare the first twenty channels field by field. A
   layout that is wrong by one field decodes perfectly and means nothing;
   this is the only step that catches it.
6. Only then: write one channel to a high, unused slot, read it back, and
   restore the backup.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: none. Neither the cable nor the BLE link pairs.
- Session state machine: ident → three-step handshake → block reads and
  writes → the link is simply closed. A dropped link resets the radio's
  session, so the ident must be repeated for each operation.
- Commands: `0x52` read, `0x57` write; no others observed.
- Payload encoding: as under Known facts.
- Timing constraints: a short settle appears to be needed after the ident is
  acknowledged and before the handshake. Unquantified — worth measuring.

## Control surface inventory (what the replacement app must support)
- Onboarding: choose the model, connect by cable or Bluetooth.
- Core: read the whole image; decode, edit and re-encode the channel records;
  write the image back.
- Settings beyond channels (squelch, timeout, backlight, DTMF) live in the
  same image and are **not** modelled by a channel-only editor. They must
  survive a write untouched, which means writing on top of a freshly read
  image rather than a synthesised one.
- Error handling: a refused write leaves the radio inconsistent; say so, and
  point at the backup.
- Persistence: the backup is the state that matters.

## Evidence checklist
- [ ] Ident acknowledged, per model, with the model's own string
- [ ] Handshake reply lengths confirmed
- [ ] Full read of the expected length
- [ ] Decode cross-checked field by field against an independent tool
- [ ] One channel written and read back identical
- [ ] Backup restored and verified byte for byte
- [ ] Settings outside the channel block unchanged by a channel write
- [ ] Timing of the post-ident settle measured

## Spec output (clean-room)
Deferred. The device-spec schema describes services, characteristics and
commands; a codeplug is a memory image, which it has no vocabulary for. A
radio spec format is worth designing only once the protocol above is
hardware-verified.

## References (URLs only)
- https://chirpmyradio.com/projects/chirp/repository/github/revisions/master/entry/chirp/drivers/baofeng_uv17Pro.py
- https://chirpmyradio.com/projects/chirp/repository/github/revisions/master/entry/chirp/drivers/baofeng_common.py
- https://chirpmyradio.com/projects/chirp/repository/github/revisions/master/entry/chirp/chirp_common.py
- https://chirpmyradio.com/projects/chirp/wiki/BLERadios
