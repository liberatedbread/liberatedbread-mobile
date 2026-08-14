# Fardriver ND-series motor controller

## Target metadata
- target_id: fardriver-controller
- app package_id(s): UNKNOWN — vendor "FarDriver" Android app is distributed as a direct
  APK download from far-driver.com, not via Play, so no package ID is confirmed. Capture
  it from an owner's handset (Settings → Apps → App info) before running apkeep.
- device class: EV motor controller (light electric vehicle / scooter conversion)
- transport(s): BLE (bolt-on bridge module; UUIDs vary per unit)
- local-only viability: **high** — the controller free-runs telemetry over BLE with no
  cloud dependency and no bonding on HM-10-style bridges. A local dashboard needs only
  notify-subscribe plus frame decode. The write path is documented and flagged `advanced`;
  its frame shape is `reported` and the payload encodings are `hypothesis`, so it needs a
  capture before it is usable (see guardrails).

## Known facts (public + observed)
- Public claims (paraphrase; links in References):
  - Retrospective Classic "Project:E" kits: 72 V, 4 kW brushless hub motor, "sinusoidal
    motor controller", keyless ignition/remote, "connected by app". App is described as
    showing speed, battery status, range and selected riding mode; speed limit can be
    restricted/derestricted via the app.
  - Retrospective publishes **no app name and no controller brand** — confirmed absent
    from the Project:E page, the per-model kit listings, and the site FAQ.
  - QS Motor ships its 4 kW hub conversion kits paired with Fardriver ND72xxx sine-wave
    controllers; community Vespa conversions report the same QS-hub + Fardriver pairing.
- Observed: none yet — no capture has been taken from a physical unit. Every protocol
  fact currently in `docs/devices/fardriver-controller.md` is derived from public
  MIT-licensed community reverse-engineering work, not from our own scan.

## Device discovery signals
- BLE:
  - advertised name patterns: UNKNOWN — bridge modules differ; record on first scan.
  - service UUIDs: `0000ffe0-...` observed commonly (HM-10-style); **per-unit, verify**.
  - **not auto-matchable**: `0xFFE0` is the generic HM-10 BLE-UART service, already
    claimed by motool-slacker and advertised by SP107E controllers. The spec therefore
    declares no identification/discovery block; selection is manual until a unique
    local-name prefix, manufacturer data, or a read-only framing probe is available.
    Finding that discriminating signal is a first-class goal of the first scan.
  - notify characteristic: `0000ffec-...` reported by one community implementation;
    `0000ffe1-...` on plain HM-10 bridges. Verify.
  - address behavior: unknown (expect public on HM-10-class modules).
- Wi-Fi: not applicable — no Wi-Fi interface on this controller.

## Threat model + guardrails
- Scope: **owner's own vehicle only.** Telemetry decode is the MVP; the write path is
  documented and supported behind an explicit opt-in.
- Writes are flagged `advanced: true` in the spec, with `advanced_reason` surfaced at the
  opt-in point. Conditions that stay non-negotiable:
  - No autodetection-triggered writes, ever. Discovery is scan-and-read only.
  - Write experimentation happens on a stand with the wheel off the ground, by the owner,
    on their own unit — never while moving.
  - Frame shape is MEDIUM confidence and CRC byte order is unverified. Confirm against a
    capture of the vendor app writing a known value before sending anything.
  - Derestriction may change a vehicle's legal classification and invalidate insurance —
    document the capability and state the consequence; the owner decides.
  - Not safety-critical: nothing here should be relied on for braking, lighting or any
    road-safety function.

## First experiments (do these first)
1) Scan the powered-on scooter with nRF Connect; record advertised name, address,
   service + characteristic UUIDs. Attach the scan export.
2) Subscribe to the notify characteristic; confirm a steady stream of 16-byte frames
   beginning `0xAA`. This confirms/refutes the Fardriver attribution for this unit.
3) Capture `btsnoop_hci.log` across one connect + one ride-mode change in the vendor app.
4) Identify the vendor app package ID from the owner's handset; add to `targets.csv`.
5) Scan with the removable pack in and out to separate the controller radio from any
   smart-BMS radio in the pack.

## Protocol hypotheses (to validate)
- Pairing/bonding: none required on HM-10-style bridges — validate.
- Session state machine: none — controller pushes telemetry once notifications are
  enabled; no keep-alive expected. Validate that a subscribe alone starts the stream.
- Framing: 16 bytes — `0xAA` magic, 6-bit block ID + 2-bit flags, 12-byte payload,
  CRC16. IDs `< 0x37` index a 55-entry flash-address table spanning `0x00`–`0xFA`;
  reassembly yields a 512-byte memory image decoded by struct offset.
- CRC16: poly `0x8005`, init `0x7F3C`, refin/refout true, xorout false. **Verify against
  real captured frames** — this is the single highest-value validation step, because it
  confirms framing and byte order at once.
- Timing constraints: frame cadence unmeasured; hot blocks reportedly repeat every 3–4
  frames. Measure.

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: scan, pick controller, remember address (no bonding expected).
- Core controls (MVP): **read-only rider dashboard** — speed, pack voltage, line current,
  SOC, motor RPM, controller and motor temperature, current ride mode.
- Power / modes: display selected ride mode. Changing it is a later, opt-in,
  owner-validated step — not MVP.
- Error handling: CRC-reject bad frames silently; surface a stale-data indicator when
  notifications stop rather than freezing last values on a moving vehicle.
- Settings persistence: wheel circumference / pole pairs for speed derivation; the
  controller's own configured wheel parameters must be read, not assumed.

## Evidence checklist
- [ ] APK hash + version code (once package ID is known)
- [ ] nRF Connect scan export (per-unit UUIDs)
- [ ] HCI snoop log (connect + mode change)
- [ ] Raw notify capture, ≥ 200 frames, for CRC and reassembly validation
- [ ] Pack-in / pack-out scan pair (BMS separation)

## Spec output (clean-room)
- `device-specs/devices/fardriver-controller.yaml`
- `docs/devices/fardriver-controller.md`

## Open questions
- Is the Retrospective "Project:E" app in fact the Fardriver app, a rebadge, or a
  third-party dashboard? Vendor attribution is currently **MEDIUM confidence, inferred**.
- Where does "range" in the vendor app come from — controller SOC plus a fixed
  Wh/mile constant, or a smart BMS in the pack?
- Is the keyless ignition/remote part of the controller's feature set or a separate
  aftermarket alarm module with its own radio?

## References (URLs only)
- https://www.retrospectivescooters.com/for-sale/project-e-electric-vespa-conversion
- https://scooterlab.uk/electric-scooter-conversons-vespa-lambretta/
- https://www.motorcyclenews.com/news/new-tech/retrospective-scooter-electric-conversion-vespa-lambretta/
- https://github.com/jackhumbert/fardriver-controllers
- https://github.com/bobecek79/ESP32-Fardriver-BLE-Reader
- https://endless-sphere.com/sphere/threads/fardriver-ble-communication.128344/
- https://endless-sphere.com/sphere/threads/fardriver-controller-serial-protocol-reverse-engineering.121825/
- https://www.cnqsmotor.com/product/electric-car-motor-conversion-kits-qs273-4000w-hub-motor-with-fardriver-nd72680/
- https://endless-sphere.com/sphere/threads/votol-em-100-em-150-controllers.95969/
