# Target: Govee H5080 BLE Smart Plug

## Target metadata
- target_id: govee-h5080-plug
- app package_id(s): com.govee.home
- device class: BLE smart plug
- transport(s): BLE
- local-only viability: high — BLE-only plug, no WiFi or cloud dependency (claimed by integration)

## Known facts (verified from RE sources)
- Govee H5080 BLE Smart Plug
- Price: $15-20
- NOTE: H5080-specific protocol documentation returned 404 from egold555/Govee-Reverse-Engineering
- NOTE: virtuald/govee-ble-plugs is a wrapper/integration, not a protocol spec
- PLAUSIBLE (unverified): Packet type 0x33 for power — matches Govee H6001 pattern
- PLAUSIBLE (unverified): Same packet framework as H6001 (0xAA/0x33 prefixes, XOR checksum)
- PLAUSIBLE (unverified): BLE-only, no WiFi radio
- TBD — needs verification: All BLE service/characteristic UUIDs
- TBD — needs verification: Advertised name patterns ("GVH5080_XXXX" speculative)
- TBD — needs verification: Exact on/off command bytes
- NOTE: This target needs hands-on verification — existing RE sources are insufficient
- Existing RE (wrappers only): github.com/virtuald/govee-ble-plugs, github.com/egold555/Govee-Reverse-Engineering

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — "GVH5080_XXXX" speculative
  - service UUIDs: TBD — likely same family as H6001 (unverified)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Smart plug controls power — avoid safety-critical loads.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.govee.home.
3) Static: grep for BLE write characteristic UUIDs, power command format.
4) Dynamic: record one "connect + toggle on/off" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: likely no bonding (matches H6001 family) — TBD
- Session state machine: connect -> write command -> disconnect (plausible, unverified)
- Commands: on/off likely 0x33-prefix (matches H6001 family) — TBD
- Payload encoding: likely 20-byte with XOR checksum (matches H6001) — TBD
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: TBD — needs BLE name verification
- Core controls (MVP): on/off toggle, get current state
- Power / brightness / modes / uploads: N/A (binary on/off)
- Error handling and recovery: reconnect on disconnect
- Settings persistence: TBD

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/govee-h5080-plug.md

## References (URLs only)
- https://github.com/virtuald/govee-ble-plugs
- https://github.com/egold555/Govee-Reverse-Engineering
