# Target: iBBQ / Inkbird BLE Meat Thermometer

## Target metadata
- target_id: ibbq-meat-thermo
- app package_id(s): com.inkbird.ibbtgo
- device class: BLE BBQ/meat thermometer (multi-probe, 2-6 probes)
- transport(s): BLE
- local-only viability: high — purely BLE, no cloud

## Known facts (verified from RE sources)
- iBBQ/Inkbird multi-probe thermometer (source: gist.github.com/uucidl iBBQ protocol + gleeds/cloudbbq)
- Price: $15-25, sold under Inkbird, Tenergy Solis, generic iBBQ brands
- VERIFIED: Service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- VERIFIED: Characteristics:
  - SettingsResult: 0xFFF1 (notify)
  - AccountAndVerify: 0xFFF2 (write)
  - HistoryData: 0xFFF3 (notify)
  - RealtimeData: 0xFFF4 (notify)
  - SettingsData: 0xFFF5 (write)
  - CCCD descriptor: 0x2902
- VERIFIED: Credential/pairing bytes: `{0x21, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0xb8, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00}` written to 0xFFF2
- VERIFIED: Enable realtime: `{0x0B, 0x01, 0x00, 0x00, 0x00, 0x00}` to 0xFFF5
- VERIFIED: Temperature as uint16 LE in 0.1C increments (divide by 10 for C), num_probes = data_length / 2
- VERIFIED: Battery request: `{0x08, 0x24, 0x00, 0x00, 0x00, 0x00}`
- VERIFIED: Celsius mode: `{0x02, 0x00, ...}`, Fahrenheit: `{0x02, 0x01, ...}`
- VERIFIED: Silence alarm: `{0x04, 0xff, 0x00, 0x00, 0x00, 0x00}`
- VERIFIED: Set target temp: `{0x01, probe#, low0, low1, high0, high1}` (temp x 10 as signed int16)
- Existing RE: github.com/gleeds/cloudbbq, gist.github.com/uucidl/b9c60b6d36d8080d085a8e3310621d64

## Device discovery signals
- BLE:
  - advertised name patterns: "iBBQ" (VERIFIED from RE source)
  - service UUIDs: `0000fff0-0000-1000-8000-00805f9b34fb` (VERIFIED)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Temperature sensor — no actuation risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.inkbird.ibbtgo.
3) Static: grep for GATT UUIDs (already well documented).
4) Dynamic: record one "connect + read temps" HCI snoop to confirm.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: credential write to 0xFFF2 required after connection (VERIFIED)
- Session state machine: connect -> write credentials -> enable CCCD -> enable realtime -> receive notifications (VERIFIED)
- Commands: credential, enable realtime, battery request, set unit, set alarm, silence alarm (ALL VERIFIED)
- Payload encoding: uint16 LE / 10 for C (VERIFIED)
- Timing constraints: notifications at regular interval after enable

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for iBBQ name
- Core controls (MVP): read temperature per probe, set alarms
- Power / brightness / modes / uploads: alarm thresholds, temperature units
- Error handling and recovery: handle probe disconnect, reconnect BLE
- Settings persistence: alarm thresholds

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/ibbq-meat-thermo.md

## References (URLs only)
- https://github.com/gleeds/cloudbbq
- https://gist.github.com/uucidl/b9c60b6d36d8080d085a8e3310621d64
