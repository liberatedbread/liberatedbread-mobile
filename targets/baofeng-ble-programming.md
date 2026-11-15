# Baofeng native BLE programming — the FFE0/FFE1 tunnel

## Target metadata
- target_id: baofeng-ble-programming
- app package_id(s): com.aewt.app.friends ("Ola Radio", Baofeng's own
  wireless-programming app)
- device class: handheld transceiver with an integrated Bluetooth LE radio
- transport(s): BLE GATT, no pairing
- local-only viability: **high**. The radio is programmed over a short-range
  link with no account, no cloud and no network. The tunnel carries the same
  serial protocol a cable would.

Confirmed members: UV-5R Mini and UV-5G Mini / "Mini 5". The UV-32 is
same-family by every public account and is treated here as a **hypothesis**
until somebody captures one.

## Known facts (public + observed)
- The radio exposes an HM-10-style GATT UART: one vendor service, one
  characteristic inside it that is both write-without-response and notify.
  It is a byte pipe. There is no framing, no length prefix and no terminator
  inside it — what goes in comes out.
- **No pairing.** The characteristic answers an unbonded link. Nothing is
  encrypted above the BLE link layer.
- What the pipe carries is the UV-17Pro serial protocol unchanged: the same
  ident string, the same three-step handshake, the same read and write
  framing, the same byte substitution. See
  [baofeng-uv17pro-family.md](baofeng-uv17pro-family.md).
- **One difference, and it matters:** uploads over Bluetooth use a 0x80-byte
  block where a cable uses 0x40. Reads stay at 0x40 either way. A client that
  assumes one block size for both directions will write half the codeplug at
  the wrong addresses.
- Replies arrive split across notifications at whatever the negotiated ATT
  MTU allows — three of them for a 0x44-byte read reply at the BLE minimum.
  Since the pipe has no framing, the only workable read is "wait for the byte
  count this command's reply will be", which the protocol makes knowable in
  advance.
- The radio's Bluetooth is enabled from its own menu, and its wireless
  programming mode from the same place. A radio with Bluetooth off does not
  advertise.

## Device discovery signals
- BLE:
  - advertised name patterns: the model name, variously punctuated. Names
    seen in the wild include the model with and without a hyphen, and
    sometimes a "MINI" spelling that does not match the printed model. **Treat
    the name as a hint, never as an identity** — what settles which radio this
    is, is which ident string it acknowledges.
  - service UUIDs: the vendor UART service in the 16-bit range, advertised.
    This is a far better filter than the name, and it is what a scanner should
    key on.
  - address behavior: public, stable across power cycles on the units
    reported.
- Wi-Fi: none.

## Threat model + guardrails
- Scope: only radios the operator owns.
- **An unbonded, unauthenticated write path into a radio's memory is worth
  naming as what it is.** Anyone in Bluetooth range can, in principle, speak
  this protocol to a radio in wireless-programming mode. That is the vendor's
  design, not a consequence of documenting it; the mitigation available to an
  owner is to leave wireless programming off when not using it. This project
  writes only to radios its user selects, and never scans-and-writes.
- Writing is destructive if it goes wrong: read and store the existing image
  first, always, and offer to restore it.
- Non-goal: nothing here defeats a protection. There is no pairing to bypass
  and no key to recover; the byte substitution in the tunnelled protocol is a
  published constant.

## First experiments (do these first)
1. Enable Bluetooth on the radio, scan, and record what it advertises: name,
   service UUIDs, address type. Confirm the UART service is in the
   advertisement rather than only in the GATT table.
2. Connect without pairing. Confirm the characteristic's properties really are
   write-without-response plus notify.
3. Send the ident string; confirm the single 0x06 arrives as a notification.
4. Read one block and observe how many notifications the reply is split into,
   and at what MTU.
5. Write one block at 0x80 and confirm the acknowledgement; then try the same
   at 0x40 and record what happens. The block-size difference is the one thing
   here that is not shared with the cable path, so it deserves its own note.
6. For the UV-32: repeat 1-3 and record whether it answers the same ident
   string. That single result promotes it from hypothesis to member, or
   removes it.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: none required.
- Session state machine: as the serial family, with the session reset when the
  link drops — so each operation re-idents.
- Commands: as the serial family.
- Payload encoding: as the serial family, with 0x80-byte write blocks.
- Timing constraints: worth measuring whether the radio needs a gap between
  consecutive writes over BLE that a cable does not.

## Control surface inventory (what the replacement app must support)
- Onboarding: tell the user to enable Bluetooth and wireless programming on
  the radio itself, because there is no way to do it from outside.
- Discovery: scan filtered by the UART service, with the name as a secondary
  hint.
- Core: connect, ident, read, write, disconnect — always disconnecting, since
  a radio left connected refuses the next client.
- Error handling: distinguish "did not answer the ident" (usually not in
  programming mode) from "stopped answering mid-session" (out of range, or
  turned off), because the recoveries differ.

## Evidence checklist
- [ ] Advertisement captured: name, service UUIDs, address type
- [ ] Characteristic properties confirmed from a real GATT table
- [ ] Ident acknowledged over BLE
- [ ] Notification split observed, with the negotiated MTU recorded
- [ ] 0x80-byte write acknowledged
- [ ] Behaviour of a 0x40-byte write over BLE recorded
- [ ] UV-32: same ident string, or not

## Spec output (clean-room)
Deferred with the rest of the family — see
[baofeng-uv17pro-family.md](baofeng-uv17pro-family.md).

## References (URLs only)
- https://chirpmyradio.com/projects/chirp/wiki/BLERadios
- https://chirpmyradio.com/issues/12251
- https://github.com/pcunning/uv5r-ble-relay
- https://chirpmyradio.com/projects/chirp/repository/github/revisions/master/entry/chirp/drivers/baofeng_uv17Pro.py
