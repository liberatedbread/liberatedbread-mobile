# Bluetooth programming adapters for K-plug radios

## Target metadata
- target_id: radio-bt-programming-adapters
- app package_id(s): com.aewt.app.friends ("Ola Radio", the app sold alongside
  Baofeng's own adapter)
- device class: Bluetooth-to-serial adapter on a radio's K-plug programming
  port
- transport(s): BLE GATT (assumed), bridging to the radio's serial protocol
- local-only viability: **unknown, and that is the finding.** The bridge is
  plausibly a transparent byte pipe, in which case supporting it is nearly
  free once the radio protocols are implemented. It is equally plausibly a
  vendor framing of its own. Nobody has published a capture either way.

Two adapters are in scope: Baofeng's own, sold for its cable-programmed
radios, and TIDRadio's, sold for theirs.

They matter most on iOS. An iPhone app gets no access to a USB-serial adapter
at all, so for a radio with no Bluetooth of its own, one of these is the only
way to program it from an iPhone.

## Known facts (public + observed)
Thin, deliberately: almost nothing about these is published, and this document
exists to say so rather than to guess.

- Both are small dongles that plug into a radio's two-pin K-plug port and
  present a Bluetooth link to a phone.
- The radios behind them speak the ordinary serial protocols documented in
  [baofeng-uv5r-family.md](baofeng-uv5r-family.md) and
  [baofeng-uv17pro-family.md](baofeng-uv17pro-family.md).
- For the TIDRadio adapter, a community project reports a GATT service with a
  write characteristic and a notify characteristic in the 16-bit range — the
  usual shape of a UART bridge. **Reported, not verified here**, and worth
  re-checking before anything is built on it.
- For the Baofeng adapter, no GATT description has been found at all. Its
  companion app is the only public client.
- A third-party dongle is also reported to work with some of these radios,
  with quirks around how it handles the link. Treat compatibility claims as
  unverified.

## Device discovery signals
- BLE:
  - advertised name patterns: unknown. Expected to name the adapter rather
    than the radio, which would make the name useless for identifying what is
    on the other end.
  - service UUIDs: unknown for the Baofeng adapter; reported for the TID one.
  - address behavior: unknown.
- Nothing else. These are BLE-only devices.

## Threat model + guardrails
- Scope: only adapters and radios the operator owns.
- Everything under the radios' own guardrails applies unchanged: the adapter
  is a pipe to the same destructive write path, so a backup first, always.
- If the bridge turns out to be transparent, an unauthenticated Bluetooth link
  into a radio's memory exists here too, with the same honest caveat as the
  radios' own Bluetooth: the mitigation available to an owner is to unplug the
  adapter when it is not in use.
- Non-goal: no attempt to work around a paired or authenticated link if one
  turns out to exist. If the adapter authenticates, that is a finding to
  record, not an obstacle to route around.

## First experiments (do these first)
1. Scan with the adapter plugged into a powered radio and record everything it
   advertises. Then scan with it unplugged, if it powers at all, and diff.
2. Dump the full GATT table. Note every characteristic and its properties;
   this alone settles the "UART bridge or not" question.
3. With the vendor app driving a read, capture the link (an HCI snoop log on
   Android). The question to answer first is narrow: **do the bytes on the
   Bluetooth link equal the bytes the serial protocol would carry?** If yes,
   the adapter is transparent and everything already documented applies. If
   no, capture enough to characterise the wrapper.
4. If transparent: confirm by speaking the radio's own ident directly through
   the characteristic and looking for the acknowledgement.
5. Record the block size the app uses over the adapter. The radios' own
   Bluetooth re-blocks writes; an adapter might too.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: unknown; possibly none, by analogy with the radios'
  own modules.
- Session state machine: hypothesised to be the radio's own, unmodified.
- Commands: hypothesised to be the radio's own.
- Payload encoding: hypothesised transparent. This is the hypothesis the
  capture in step 3 exists to test.
- Timing constraints: unknown, and likely the interesting part — a bridge
  adds latency and may need a slower cadence than a cable.

## Control surface inventory (what the replacement app must support)
Nothing yet. Until step 3 answers, there is no surface to design against.
If the bridge is transparent, the surface is exactly the radios' own and the
adapter becomes a transport detail rather than a device: a byte pipe that
writes, and reads an exact number of bytes with a timeout — which is all the
serial protocol in [baofeng-uv5r-family.md](baofeng-uv5r-family.md) asks of
a cable. Two things a cable does that a bridge may not, worth checking in
step 3: the paced, byte-at-a-time magic, and the stray 0x06 that precedes
every read answer after the first.

## Evidence checklist
- [ ] Advertisement captured for each adapter
- [ ] Full GATT table dumped for each adapter
- [ ] Link capture of the vendor app performing a read
- [ ] Transparent-or-not answered, per adapter
- [ ] If transparent: ident acknowledged through the adapter directly
- [ ] Block size used by the vendor app recorded

## Spec output (clean-room)
Nothing to write yet.

## References (URLs only)
- https://chirpmyradio.com/projects/chirp/wiki/BLERadios
- https://github.com/rvcx/radioble
- https://chirpmyradio.com/projects/chirp/repository/github/revisions/master/entry/chirp/drivers/tdh8.py
