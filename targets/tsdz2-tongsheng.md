# Tongsheng TSDZ2 mid-drive motor

## Target metadata
- target_id: tsdz2-tongsheng
- app package_id(s): none — no app and no radio exists for this motor.
- device class: e-bike mid-drive motor + integrated controller
- transport(s): UART (9600 baud TTL, 6-pin Tongsheng display connector)
- local-only viability: **very high, and already mostly achieved.** The protocol is public
  and open-source firmware already replaces the stock firmware. The remaining gap is
  wireless access — nothing bridges this serial link to a phone or hub today.

## Known facts (public + observed)
- 9600 baud TTL, 8N1. **Not** the BBS02's 1200 baud — different family entirely.
- Continuous bidirectional stream, no request/response: motor→display 9-byte packets at
  8 Hz starting `0x43`; display→motor 7-byte packets at 15 Hz starting `0x59`.
- Checksum is an 8-bit sum of preceding bytes, both directions. 16-bit values little-endian.
- Motor→display: battery level, status flags, torque tara + current value, error code
  (`0x08` undervoltage), 16-bit speed.
- Display→motor: control flags (light, assist level, 6 km/h walk mode), wheel size in
  inches (default `0x1A` = 26″), max speed in km/h (default `0x19` = 25).
- Wiring: brown = motor TX, orange = motor RX.
- Stock displays sharing the protocol: VLCD5, VLCD6, XH18. OSF adds SW102, DZ41, 850C, 860C.
- Observed: nothing. All of the above is `reported` from community documentation.

## Device discovery signals
- Not discoverable — wired, point-to-point, no advertisement of any kind.
- Identify by connecting at 9600 and looking for `0x43`-led 9-byte packets at ~8 Hz. Seeing
  that stream is itself the identification.

## Threat model + guardrails
- Scope: **owner's own bike only.**
- The control packet *is* the write path — there is no separate configuration exchange.
  Anything that transmits on this bus is setting wheel size and max speed, 15 times a
  second. A "read-only" tool here means **listen only, never transmit**.
- Raising the max-speed byte is derestriction; on a pedelec it can move the bike out of
  EAPC/pedelec classification, changing licence, insurance and road access. Flag `advanced`
  and state the consequence; the owner decides.
- Do not transmit onto a bus that still has the stock display attached without
  understanding contention — two transmitters asserting different max speeds is untested.
- Not safety-critical: nothing here is a substitute for mechanical brake service.

## First experiments (do these first)
1) Passive capture only: USB-TTL adapter on the brown line, 9600 8N1, confirm 9-byte
   `0x43` packets at ~8 Hz. Two minutes of capture is enough.
2) Verify the 8-bit sum checksum against those captured frames — this validates framing and
   byte order at once, exactly as it does on the BBS02.
3) Capture the display→motor direction on the orange line; confirm `0x59`, 7 bytes, ~15 Hz.
4) Establish which firmware is running **before** interpreting anything: OSF changes the
   protocol, so a capture that disagrees with the documented layout most likely means OSF.
5) Diff single-variable changes — one assist level step, headlight on/off — to confirm the
   control-flag bit positions, which are the least precisely documented part.

## Protocol hypotheses (to validate)
- Display packet bytes 2 and 4 are undocumented even in the sources. Unknown, not zero —
  capture and see.
- Control-flag bit assignments (assist levels, walk mode, hidden level) are described but
  the exact bit order is worth confirming by diffing.
- Whether the motor tolerates a passive listener while the stock display is attached — a
  shared line may or may not permit a third party. Test before assuming.
- Torque tara vs current value: the pair should yield applied torque, but the scaling to
  real units is not documented.

## Control surface inventory (what the replacement app must support)
- Onboarding: serial port selection; no pairing exists.
- Core (MVP): **listen-only dashboard** — speed, battery level, torque, error code, motor
  running state. This is genuinely useful and carries no write risk at all.
- Advanced (opt-in): asserting wheel size and max speed, i.e. becoming the display. Only
  meaningful for a replacement-display product, and it is a continuous transmit role, not
  a one-shot write.
- Error handling: reject bad checksums silently; show a stale indicator if the 8 Hz stream
  stops rather than freezing values on a moving bike.

## Evidence checklist
- [ ] Motor→display capture, ≥ 1000 frames, for checksum and field validation
- [ ] Display→motor capture, same
- [ ] Firmware provenance noted (stock vs OSF, and OSF version)
- [ ] Single-variable diffs for control-flag bits
- [ ] Bus contention test result (passive listener alongside stock display)

## Spec output (clean-room)
- `docs/devices/tsdz2-tongsheng.md`
- `device-specs/devices/tsdz2-tongsheng.yaml` — `bus` spec, `protocol: uart`,
  `style: stream`. Both packet shapes with `start_byte`/`length`/`rate_hz` and full field
  tables; `display_control` marked `writes: true` + `advanced` because in stream style a
  control packet writes by existing. Entities bind via `state_field`. The two undocumented
  display bytes are recorded as `hypothesis` fields rather than omitted.

## Open questions
- Does a bridge already exist? Nothing found that puts this link on BLE — an ESP32 bridge
  is the obvious small project and would serve the BBS02 too.
- Do TSDZ2B controllers use the same packet layout?
- Does OSF's protocol diverge enough to need its own page, or a variants section here?

## References (URLs only)
- https://github.com/hurzhurz/tsdz2/blob/master/serial-communication.md
- https://github.com/hurzhurz/tsdz2
- https://github.com/OpenSourceEBike/TongSheng_TSDZ2_motor_controller_firmware
- https://github.com/emmebrusa/TSDZ2-Smart-EBike-1
- https://github.com/OpenSource-EBike-firmware/TSDZ2_wiki/wiki/Communication-Protocol
