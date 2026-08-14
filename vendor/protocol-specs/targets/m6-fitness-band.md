# Target: M6 Smart Fitness Band

## Target metadata
- target_id: m6-fitness-band
- app package_id(s): TBD — "com.m6.fitness" was speculative; actual companion app package unknown
- device class: BLE fitness tracker / smartband
- transport(s): BLE
- local-only viability: high — purely BLE, no cloud required for basic operation

## Known facts (verified from RE sources)
- M6 Smart Fitness Band / cheap Mi Band 6 clone (source: rbaron.net blog post)
- Price: ~$6 (AliExpress)
- VERIFIED: Uses Telink TLSR8232 SoC (32-bit tc32, ~24 MHz, 16kB SRAM, 512kB flash)
- VERIFIED: OLED display (ST7735 driver IC), vibration motor, optical PPG heart rate sensor
- VERIFIED: SWS (Single Wire Slave) debug interface accessible for firmware dumping/flashing
- VERIFIED: Capacitive button on GPIO_PC2
- VERIFIED: Hardware fully torn down with custom firmware written and flashed via SWD
- IMPORTANT: The rbaron.net RE is HARDWARE-ONLY — it does NOT document the phone-to-device BLE protocol
- The blog author used nRF Connect (generic BLE tool), NOT a proprietary companion app
- TBD — needs verification: All BLE GATT service/characteristic UUIDs (not documented)
- TBD — needs verification: Companion app package ID (previously "com.m6.fitness" was fabricated)
- TBD — needs verification: Advertised name patterns
- TBD — needs verification: BLE command encoding for step count, heart rate, alarms, time sync
- NOTE: This target has hardware RE only; BLE app protocol is entirely undocumented — true greenfield
- Existing RE: rbaron.net (hardware only)

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — "M6", "M6 Band" are speculative
  - service UUIDs: TBD
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Fitness tracker — heart rate data is indicative only, not medical grade.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Identify actual companion app used with M6 bands (scan Play Store for compatible apps).
3) Fetch APK for identified companion app; decompile and identify BLE GATT layer.
4) Dynamic: record one "connect + sync" HCI snoop with companion app.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: TBD — likely requires bonding
- Session state machine: TBD
- Commands: TBD — expect time sync, step count read, heart rate read, alarm set
- Payload encoding: TBD — likely proprietary binary framing
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: TBD
- Core controls (MVP): read step count, read heart rate, set time
- Power / brightness / modes / uploads: alarms, notifications, sedentary reminders
- Error handling and recovery: reconnect, handle sync failures
- Settings persistence: device stores step/HR data internally (VERIFIED from hardware RE)

## Evidence checklist
- APK hashes + version code: TBD — companion app not yet identified
- HCI snoop log: TBD
- Hardware RE: SWS dump available (rbaron.net)

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/m6-fitness-band.md

## References (URLs only)
- https://rbaron.net/blog/2021/07/06/Reverse-engineering-the-M6-smart-fitness-band.html
