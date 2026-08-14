# MoTool Slacker target spec

## Target metadata
- target_id: motool-slacker
- app package_id(s): co.motool.serviceassistant
- device class: motorcycle suspension tuner (digital sag tool)
- transport(s): BLE
- local-only viability: high -- BLE sag measurement is entirely local; subscription gates the "virtual remote" feature in the app

## Known facts (public + observed)
- MoTool Slacker V4/V5 is a digital motorcycle suspension sag measurement tool
- Attaches to fork/shock, communicates over BLE to phone app
- App provides "virtual remote" feature to trigger sag measurement from phone
- Manufacturer added subscription paywall to the virtual remote feature
- No known community reverse engineering efforts
- Device likely uses simple BLE commands (start/stop measurement, read value)

## Device discovery signals
- BLE:
  - advertised name patterns: unknown -- to be discovered from APK
  - service UUIDs: unknown -- to be discovered from APK
  - address behavior (public/random): unknown

## Threat model + guardrails
- Scope: only owned devices; motorcycle suspension measurement only.
- Non-goals: no firmware modification, no safety-critical control.
- Goal: restore virtual remote functionality that was subscription-gated.

## First experiments (do these first)
1) Fetch APK: `apkeep -a co.motool.serviceassistant`
2) Static: run `scripts/run_static_target.sh motool-slacker`
3) Grep for UUIDs, BLE service discovery, command patterns
4) Identify subscription/paywall check code vs BLE-level commands

## Protocol hypotheses (to validate)
- Pairing/bonding steps: likely Just Works or no bonding (simple tool)
- Session state machine: connect -> discover services -> write command -> read/notify result
- Commands: start measurement, stop measurement, read sag value, possibly calibrate
- Payload encoding: likely simple byte commands or short integer values
- Timing constraints: unknown

## Control surface inventory (what the replacement app must support)
- Device discovery and connection
- Virtual remote: trigger sag measurement start/stop
- Read sag measurement value
- Possibly calibration/zero commands

## Evidence checklist
- APK hashes + version code: pending
- HCI snoop log: pending

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/motool-slacker.md
- device-specs/devices/motool-slacker.yaml

## References (URLs only)
- https://play.google.com/store/apps/details?id=co.motool.serviceassistant
- https://motool.com
