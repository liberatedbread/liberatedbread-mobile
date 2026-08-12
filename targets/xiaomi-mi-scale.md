# Target: Xiaomi Mi Scale BLE Body Composition Scale

## Target metadata
- target_id: xiaomi-mi-scale
- app package_id(s): com.xiaomi.hm.health (Zepp Life, formerly Mi Fit)
- device class: BLE body composition scale
- transport(s): BLE
- local-only viability: high — BLE protocol RE'd via openScale project

## Known facts (verified from RE sources)
- Xiaomi Mi Scale v1 and v2 (source: oliexdev/openScale wiki)
- Price: $20-30
- VERIFIED: Weight Scale service UUID: `0000181d-0000-1000-8000-00805f9b34fb` (NOTE: NOT 0x181B as previously stated)
- VERIFIED: Custom service UUID: `00001530-0000-3512-2118-0009af100700`
- VERIFIED: Device Info service: `0000180a-0000-1000-8000-00805f9b34fb`
- VERIFIED: Weight Measurement char: `00002a9d`
- VERIFIED: Weight Scale Feature char: `00002a9e`
- VERIFIED: History char: `00002a2f-0000-3512-2118-0009af100700`
- VERIFIED: Current Time char: `00002a2b`
- VERIFIED: 10-byte weight packet: [control_byte, weight_lo, weight_hi, year_lo, year_hi, month, day, hour, min, sec]
- VERIFIED: Control byte bit layout: Bit0=LBS, Bit4=Jin, Bit5=Stabilized, Bit7=WeightRemoved
- VERIFIED: Weight division: /100 for lbs/jin, /200 for kg
- VERIFIED: Valid measurement only when Bit5 (stabilized) = true AND Bit7 (removed) = false
- VERIFIED: History protocol: enable notify on 0x2A2F, write `01 FF FF FF FF`, re-enable, write `02`, receives data ending with `03`
- VERIFIED: Set time by writing to 0x2A2B: [year_lo, year_hi, month, day, hour, min, sec, 0x03, 0x00, 0x00]
- V2 adds impedance measurement for body composition
- Existing RE: github.com/oliexdev/openScale

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — "MIBCS", "MI_SCALE", "XMTZC" are unconfirmed speculation
  - service UUIDs: `0000181d-...` (Weight Scale) (VERIFIED)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Weight measurement — health data, handle with privacy awareness.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.xiaomi.mifit.
3) Static: grep for weight scale GATT service UUIDs.
4) Dynamic: capture BLE weight measurement notification.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: minimal or none for basic weight reading (VERIFIED from openScale)
- Session state machine: connect -> subscribe -> step on -> receive measurement -> disconnect (VERIFIED)
- Commands: N/A (read-only); history via 0x2A2F write sequence (VERIFIED)
- Payload encoding: 10-byte packet with control flags + LE int16 weight + timestamp (VERIFIED)
- Timing constraints: notifications sent when weight stabilizes (VERIFIED)

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for scale (name pattern TBD)
- Core controls (MVP): read weight, read unit (kg/lbs)
- Power / brightness / modes / uploads: body composition (v2), history download
- Error handling and recovery: handle unstable readings
- Settings persistence: weight unit preference

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/xiaomi-mi-scale.md

## References (URLs only)
- https://github.com/oliexdev/openScale
- https://github.com/oliexdev/openScale/wiki/Xiaomi-Bluetooth-Mi-Scale
