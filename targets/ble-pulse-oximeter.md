# Target: BLE Pulse Oximeter (BerryMed / SP001)

## Target metadata
- target_id: ble-pulse-oximeter
- app package_id(s): TBD — "com.viatom.oxyfit" was speculative; actual companion app may differ
- device class: BLE pulse oximeter
- transport(s): BLE
- local-only viability: high — purely BLE, no cloud required

## Known facts (verified from RE sources)
- BerryMed / SP001 / generic BLE fingertip pulse oximeters
- Price: $15-30
- VERIFIED: Measures SpO2 (blood oxygen saturation) and pulse rate
- VERIFIED: Uses BLE GATT (not standard 0x1822 Pulse Oximeter profile in most cheap units)
- NOTE: jcomas/PulseOximeterSP001 repo exists with basic implementation (not marked WIP by author; reads SpO2/PR/PI data)
- TBD — needs verification: All BLE service/characteristic UUIDs (not documented in cited repo)
- TBD — needs verification: "BCI protocol documented" claim (unverified)
- TBD — needs verification: Advertised name patterns ("BerryMed", "SP001" speculative)
- TBD — needs verification: Data frame format, notification rate
- TBD — needs verification: Companion app package ID
- NOTE: This target has weak RE coverage — needs hands-on work
- Existing RE: github.com/jcomas/PulseOximeterSP001

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — "BerryMed", "SP001" are speculative
  - service UUIDs: TBD — custom service (not standard 0x1822)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Medical device caveat: readings are indicative only, not for clinical diagnosis.
- Do not rely on RE'd protocol for medical decisions.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Identify actual companion app; fetch APK.
3) Static: grep for GATT service/characteristic UUIDs.
4) Dynamic: record one "connect + read SpO2/pulse" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: TBD — likely none for cheap oximeters
- Session state machine: TBD — likely connect -> subscribe -> receive readings
- Commands: TBD — likely read-only (device streams when finger inserted)
- Payload encoding: TBD — likely proprietary binary with SpO2 %, pulse bpm
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: TBD
- Core controls (MVP): read SpO2 percentage, read pulse rate
- Power / brightness / modes / uploads: TBD
- Error handling and recovery: detect finger removal, reconnect
- Settings persistence: N/A

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/ble-pulse-oximeter.md

## References (URLs only)
- https://github.com/jcomas/PulseOximeterSP001
