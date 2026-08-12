# Bafang BBS02 mid-drive motor

## Target metadata
- target_id: bafang-bbs02
- app package_id(s): `com.eggbikes.EggRider` (EggRider V2 BLE display app — third-party
  bridge, not a Bafang app). No official Bafang app exists for this motor family:
  Bafang Go / BESST targets the CAN-bus M-series (M500/M510/M600), not BBS0x.
- device class: e-bike mid-drive motor + integrated controller
- transport(s): UART (1200 baud, native); BLE only via an aftermarket bridge display
- local-only viability: **high, and largely already achieved** — the configuration
  protocol is fully public and MIT-licensed open tooling exists (OpenBafangTool), plus
  open replacement firmware (bbs-fw). The remaining gap is *wireless* local access:
  today that means a USB cable or a proprietary BLE display.

## Known facts (public + observed)
- The BBS02 has **no radio**. Every app-based route is a bridge someone bolted onto the
  UART bus.
- Serial: 1200 baud on the shared display/controller harness line.
- Read opcodes: `0x11 0x50` firmware, `0x11 0x51 0x04 0xB0 0x05` device info (16 B),
  `0x11 0x52` basic (24 B), `0x11 0x53` pedal assist (11 B), `0x11 0x54` throttle (6 B),
  `0x14 0x12/0x13/0x14/0x15/0x16` power spec / system code / serial / errors / model.
- Write opcodes: `0x16 0x52` basic, `0x16 0x53` pedal, `0x16 0x54` throttle,
  `0x17 0x01` serial number. Payload layout matches the corresponding read.
- Checksums differ by direction: read responses sum every preceding byte; write requests
  sum only the second code byte, the length and the data. Both mod 256.
- Observed: none — nothing captured from a physical unit yet. Everything above is
  transcribed from public MIT-licensed documentation.

## Device discovery signals
- UART: not discoverable — wired, point-to-point on the harness. Identify by reading
  `0x14 0x13` (system code) and `0x14 0x12` (power specification code).
- BLE (bridge only): EggRider V2 advertises as a BLE peripheral; **service and
  characteristic UUIDs are undocumented publicly** and must be captured with nRF Connect.
- Wi-Fi: not applicable.

## Threat model + guardrails
- Scope: **owner's own bike only.**
- Reads are unrestricted. All four write opcodes are `advanced`:
  - Current limits are thermal limits — over-current cooks the nylon primary gear and the
    controller MOSFETs; the motor will not protect itself.
  - Low-voltage cutoff protects the pack; lowering it drives cells into over-discharge.
  - Throttle-from-zero and speed-limit changes can move the bike out of pedelec/EAPC
    classification, changing licence, insurance and road-access status.
  - Serial-number writes (`0x17 0x01`) are effectively irreversible and can break warranty
    and dealer-tool workflows. Legitimate uses exist (restoring identity after a controller
    swap is a normal repair-bench job), so it ships like any other advanced command — the
    reason string just has to be honest that there is no undo.
  - Always read the block first and keep a copy: writes replace the **whole** block, so a
    partial edit silently rewrites fields you did not intend to touch.
- Not safety-critical: nothing here should be relied on for braking or road safety.

## First experiments (do these first)
1) Connect the USB programming cable; confirm 1200 baud and read `0x14 0x13` (system code)
   plus `0x11 0x50` (firmware). Two successful reads validate wiring and framing at once.
2) Read and archive all three parameter blocks (`0x52`, `0x53`, `0x54`) as the restore
   point before any write is attempted.
3) Verify both checksum rules against captured traffic — the direction-dependent rule is
   the most common cause of rejected writes.
4) Write back an unmodified block and confirm the controller accepts it. This validates
   the write path with zero behavioural change.
5) Only then vary one field, on a stand, and re-read to confirm the round trip.
6) If an EggRider V2 is available: scan with nRF Connect, capture the BLE service and
   characteristic UUIDs, and check whether it tunnels these opcodes verbatim.

## Protocol hypotheses (to validate)
- Block field order, sizes and encodings are `reported` — corroborated across three
  independent implementations (OpenBafangTool and two bafang-python forks) but not read
  back from a physical unit by us. Confirm against what the vendor tool renders.
- Assist limits in the basic block are **two arrays of 10**, not 10 interleaved
  `(current, speed)` pairs: current limits at payload offsets 2–11, speed limits at 12–21.
  An earlier revision of this sheet had it as pairs — that was wrong, and it is the kind of
  error that produces plausible values on the wrong assist level rather than an obvious
  failure. Verify by changing one level and diffing the block.
- Write length byte is ambiguous across sources (`0x24`/`0x11` vs the read responses'
  `0x18`/`0x0B`). Capture a vendor-tool write to settle it.
- Whether the bus tolerates a passive listener while a display is attached (needed for a
  non-invasive capture) is unknown — test before assuming.

## Control surface inventory (what the replacement app must support)
- Onboarding: serial port selection (cable) or BLE bridge pairing.
- Core controls (MVP): read and display firmware, device info, error codes, and all three
  parameter blocks; archive/restore blocks to a file.
- Advanced (behind a deliberate action): edit and write basic / pedal assist / throttle
  blocks, plus the serial-number write, with a mandatory read-first, a visible diff of what
  will change, and the `advanced_reason` shown at the confirmation step. Available to any
  user who opts in — a repair café should not have to reach for a different tool.
- Error handling: surface the write-response error parameter index — it names which field
  the controller rejected.

## Evidence checklist
- [ ] Serial capture of a full read cycle (all blocks)
- [ ] Archived pre-change parameter blocks
- [ ] Checksum verification against captured frames, both directions
- [ ] Round-trip write test (unmodified block)
- [ ] EggRider BLE scan export, if a bridge is available

## Spec output (clean-room)
- `docs/devices/bafang-bbs02.md`
- `device-specs/devices/bafang-bbs02.yaml` — `bus` spec, `protocol: uart`,
  `style: request_response`. Every read/write catalogued with field tables; the four writes
  flagged `advanced`. The assist-limit arrays are encoded as two `array_len: 10` fields, so
  the interleaved-pairs misreading is structurally impossible. The write length byte is
  deliberately not asserted while it remains ambiguous.

## Open questions
- Does the EggRider V2 tunnel these opcodes verbatim over BLE, or re-encode them?
- Do BBS02B (later revision) controllers use the same block sizes?
- Are the `0x14 0x15` error codes a bitfield or a list of active fault bytes?

## References (URLs only)
- https://github.com/andrey-pr/OpenBafangTool/blob/master/docs/Bafang%20UART%20protocol.md
- https://github.com/andrey-pr/OpenBafangTool/blob/master/docs/Bafang%20UART%20motor%20API.md
- https://github.com/danielnilsson9/bbs-fw
- https://endless-sphere.com/sphere/threads/protocol-specs-for-bafang-bbs02-mid-drive.60591/
- https://shop.eggrider.com/eggrider-v2
- https://play.google.com/store/apps/details?id=com.eggbikes.EggRider
- https://manual.eggrider.com/mobile_app/overview/
