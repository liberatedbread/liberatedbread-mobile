# Target: ETEKCITY ESN00 BLE Smart Kitchen/Nutrition Scale

## Target metadata
- target_id: etekcity-smart-scale
- app package_id(s): com.etekcity.vesyncplatform
- device class: BLE kitchen/nutrition scale
- transport(s): BLE
- local-only viability: TBD — BLE protocol only partially explored

## Known facts (verified from RE sources)
- ETEKCITY ESN00 Smart Nutrition Scale
- Price: $20-30
- VERIFIED (source: dev.to/hertzg writeup): Methodology used Android HCI snoop + Wireshark to explore BLE traffic
- VERIFIED: APK decompilation reveals serialization details
- NOTE: The dev.to article documents RE methodology but does NOT provide a complete protocol spec
- This is a genuine greenfield opportunity — no complete BLE protocol documentation exists
- TBD — needs verification: All BLE service/characteristic UUIDs
- TBD — needs verification: Advertised name patterns ("Etekcity", "ESN00" are speculative)
- TBD — needs verification: Data encoding format
- Existing RE: partial methodology only (dev.to/hertzg/hacking-ble-kitchen-scale-55io)

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — "Etekcity", "ESN00" are speculative
  - service UUIDs: TBD
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Kitchen scale — no safety risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.vesync.vesync.
3) Static: decompile APK, identify BLE serialization and GATT UUIDs.
4) Dynamic: record one "connect + weigh item" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: TBD
- Session state machine: TBD
- Commands: TBD — tare, unit change expected based on device function
- Payload encoding: TBD — binary serialization found in APK but not documented
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: TBD
- Core controls (MVP): read weight, tare, change units
- Power / brightness / modes / uploads: nutritional tracking (if supported)
- Error handling and recovery: reconnect on disconnect
- Settings persistence: unit preference

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/etekcity-smart-scale.md

## References (URLs only)
- https://dev.to/hertzg/hacking-ble-kitchen-scale-55io
