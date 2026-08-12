# Target: Govee H6001 BLE Smart Bulb

## Target metadata
- target_id: govee-h6001-bulb
- app package_id(s): com.govee.home
- device class: BLE smart bulb
- transport(s): BLE
- local-only viability: high — BLE protocol fully reverse-engineered for local control

## Known facts (verified from RE sources)
- Govee H6001 BLE LED smart bulb (source: chvolkmann/govee_btled)
- Price: ~$13
- VERIFIED: Command prefix 0x33 for control commands
- VERIFIED: 0xAA prefix for acknowledgment packets
- VERIFIED: 20-byte packets, zero-padded, with XOR checksum of all bytes in final byte
- VERIFIED: Power on: `33 01 01 00...00 <xor>`, Power off: `33 01 00 00...00 <xor>`
- VERIFIED: Brightness: `33 04 <val> 00...00 <xor>` (val = 0x00-0xFF)
- VERIFIED: Color RGB: `33 05 02 <R> <G> <B> 00...00 <xor>`
- TBD — needs verification: BLE service/characteristic UUIDs (not documented in govee_btled source)
- TBD — needs verification: Advertised name pattern ("ihoment_H6001_XXXX" is unconfirmed)
- Existing RE: github.com/chvolkmann/govee_btled, blog.coding.kiwi

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — needs verification (unconfirmed in RE sources)
  - service UUIDs: TBD — not documented in primary RE source
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Light bulb only — no safety risk beyond light output.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.govee.home.
3) Static: grep for UUIDs/endpoints + identify BLE write characteristic.
4) Dynamic: record one "connect + set color" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: no bonding, open BLE write (VERIFIED)
- Session state machine: connect -> write -> disconnect
- Commands: power `33 01 01/00`, brightness `33 04 <val>`, color `33 05 02 <RGB>` (VERIFIED)
- Payload encoding: 20-byte packets with XOR checksum in final byte (VERIFIED)
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: TBD — needs BLE name verification
- Core controls (MVP): on/off, color (RGB), brightness
- Power / brightness / modes / uploads: TBD — color temp/scene modes unconfirmed
- Error handling and recovery: reconnect on disconnect
- Settings persistence: TBD

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/govee-h6001-bulb.md

## References (URLs only)
- https://github.com/chvolkmann/govee_btled
- https://github.com/egold555/Govee-Reverse-Engineering
- https://blog.coding.kiwi/reverse-engineering-govee-smart-lights/
- https://www.xda-developers.com/reverse-engineered-govee-smart-lights-smart-home/
