# Bosch Performance Line CX (Gen4) eBike system

## Target metadata
- target_id: bosch-ebike-cx-gen4
- app package_id(s): Bosch **eBike Flow** (consumer app); dealer diagnostic tooling is
  separate and not publicly distributed. Package IDs not yet captured.
- device class: e-bike mid-drive motor, display and battery on a shared CAN bus
- transport(s): CAN, 500 kbit/s
- local-only viability: **low today, high value.** No BLE or serial link to scan; getting on
  the bus needs a CAN interface and harness access. Public RE is early — bus parameters and
  one frame, no message catalogue.

## Why this one matters
The most closed mainstream e-bike system, and the one that most often blocks an independent
repair. Fault detail, component pairing and firmware updates are gated behind dealer
tooling, so a workshop can see that a bike has faulted without being able to say why, and
cannot re-pair a replacement motor, battery or display. That is the exact dependency this
project exists to document — which is why it is worth attempting despite being the hardest
target in the registry.

## Known facts (public + observed)
- CAN at **500 kbit/s** (`ip link set can0 type can bitrate 500000`).
- Breakout via D-Sub 9 per CiA DS-102: pin 2 CAN_L (yellow), pin 3 ground (black),
  pin 7 CAN_H (green), pin 8 RTH, pin 1 RTL, red = +12 V max 1 A.
- One documented frame: `061#00`, a start/stop command (`cansend can0 061#00`).
- Kiox display internals: STM32F469IIH6 CPU, W25M512JV 512 Mbit SPI flash, W9864G6KH
  64 Mbit SDRAM.
- Community work at git.cccfr.de/bosch-nerds/ebike is small (a handful of commits);
  Pedelecforum.de holds further findings that are not in repo form.
- Observed: nothing. Everything above is `reported`, and the single frame is `hypothesis`
  until reproduced.

## Device discovery signals
- None wireless. Identification is physical: the connector, the Kiox display, the bus
  responding at 500 kbit/s.

## Threat model + guardrails
- Scope: **owner's own bike only**, and realistically a bike whose owner accepts the risk.
- **Passive capture first, always.** Do not transmit until the bus is understood; this is a
  bus with a motor on it.
- Everything that transmits is `advanced`. Specific consequences to state plainly:
  - Bosch detects tampering (tuning dongles are detected and recorded). A flagged unit can
    be refused service and lose warranty — a consequence that outlives the change.
  - Derestriction moves the bike out of EAPC/pedelec class, changing licence, insurance and
    road access.
  - Component pairing is the legitimate motivating case *and* the operation most likely to
    leave a bike unusable mid-way. Know the recovery path first.
- Wheel off the ground for any transmit test.
- Not safety-critical: nothing here substitutes for the service manual.

## First experiments (do these first)
1) Build the D-Sub 9 breakout; confirm the bus with `candump` at 500 kbit/s. Getting a
   clean passive capture is the whole first milestone.
2) Capture a full session passively: power-on, each assist level, walk mode, and a
   deliberately induced fault (e.g. unplug a sensor with the bike on a stand).
3) Diff captures across single-variable changes to isolate candidate IDs for assist level,
   speed, cadence, battery SoC.
4) Identify which IDs originate from which node (motor, display, battery) by capturing with
   components disconnected one at a time.
5) Only then consider replaying a known-safe frame. `061#00` is the only published
   candidate and should be reproduced before anything else is attempted.

## Protocol hypotheses (to validate)
- Whether Gen4 uses plain periodic broadcast frames (likely, for telemetry) alongside a
  request/response diagnostic layer (likely, for dealer tooling) on the same bus.
- Whether any authentication or rolling counter protects state-changing frames — Bosch's
  tamper detection implies at least integrity checking somewhere.
- Whether the `061` ID is a real command or an artefact of one setup.
- Whether the Kiox is a bus master or just another node.

## Control surface inventory (what a replacement tool must support)
- Core (MVP): **read-only diagnostics** — live telemetry and, above all, fault codes with
  meanings. Fault visibility alone would remove much of the dealer dependency.
- Advanced (opt-in, gated): component pairing after a part swap. This is the headline
  capability and the riskiest.
- Explicitly not a goal: speed tuning. It is documentable if it emerges, but the project's
  motivating case here is repair, not derestriction.

## Evidence checklist
- [ ] Passive `candump` of a full power-on-to-fault session
- [ ] Per-node captures (components disconnected individually)
- [ ] Single-variable diffs for assist level and speed
- [ ] Reproduction (or refutation) of `061#00`
- [ ] Hardware notes: exact motor/display/battery part numbers and firmware versions

## Spec output (clean-room)
- `docs/devices/bosch-ebike-cx-gen4.md`
- `device-specs/devices/bosch-ebike-cx-gen4.yaml` — `bus` spec, `protocol: can`,
  `style: broadcast`. Bitrate and the full D-Sub 9 breakout as `wiring` entries; the message
  catalogue holds exactly one frame, marked `hypothesis` and `advanced`. A one-entry
  catalogue is the honest output — the spec exists so confirmed frames have somewhere to
  land, not because the protocol is understood.

## Open questions
- Do Gen2/Gen3 systems share the bus format, or is each generation its own target?
- Are Nyon/Purion/Intuvia displays interchangeable at the protocol level with Kiox?
- Is there a service/diagnostic connector at all, or is harness interception the only way in?

## References (URLs only)
- https://git.cccfr.de/bosch-nerds/ebike
- https://hackaday.com/2023/11/08/an-open-source-ebike-motor-controller/
