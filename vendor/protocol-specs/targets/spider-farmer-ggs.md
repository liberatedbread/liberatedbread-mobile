# Target: Spider Farmer GGS BLE Grow Light Controller

## Target metadata
- target_id: spider-farmer-ggs
- app package_id(s): TBD — "spider.farmer" was speculative; actual package unknown
- device class: BLE grow light controller
- transport(s): BLE
- local-only viability: high — BLE protocol RE'd, ESP32 MQTT bridge available

## Known facts (verified from RE sources)
- Spider Farmer GGS grow light controller (source: cr0ssn0tice/Spider-Farmer-GGS-Controller-MQTT)
- Price: $30-50
- VERIFIED: Service UUID: `0000ff00-0000-1000-8000-00805f9b34fb`
- VERIFIED: Notify characteristic: `0000ff01-0000-1000-8000-00805f9b34fb`
- VERIFIED: Write characteristic: `0000ff02-0000-1000-8000-00805f9b34fb`
- VERIFIED: Advertised BLE name: "SF-GGS-CB"
- VERIFIED: Device sends JSON telemetry (unencrypted) with fields: temp, humi, vpd, fan, light
- VERIFIED: ESP32 MQTT bridge implemented for cloud-free local control
- Marketed as requiring cloud but actually uses simple local BLE protocol
- Relevant to OpenGreenIoT mission (literal plant growing hardware)
- TBD — needs verification: Write command format for brightness/on/off (not explicitly documented)
- TBD — needs verification: Companion app package ID
- Existing RE: github.com/cr0ssn0tice/Spider-Farmer-GGS-Controller-MQTT

## Device discovery signals
- BLE:
  - advertised name patterns: "SF-GGS-CB" (VERIFIED)
  - service UUIDs: `0000ff00-0000-1000-8000-00805f9b34fb` (VERIFIED)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Controls grow lights — moderate power draw, but no critical safety risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Identify and fetch APK for Spider Farmer companion app.
3) Static: grep for BLE UUIDs and JSON command formats.
4) Dynamic: record one "connect + set light level" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: TBD
- Session state machine: connect -> subscribe to 0xFF01 -> receive JSON telemetry; write commands to 0xFF02
- Commands: TBD — brightness/on/off write format not documented in source
- Payload encoding: JSON telemetry on notify (VERIFIED); write format TBD
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for "SF-GGS-CB" name (VERIFIED)
- Core controls (MVP): on/off, brightness/dimming level
- Power / brightness / modes / uploads: scheduling, timer modes (TBD)
- Error handling and recovery: reconnect on disconnect
- Settings persistence: TBD

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/spider-farmer-ggs.md

## References (URLs only)
- https://github.com/cr0ssn0tice/Spider-Farmer-GGS-Controller-MQTT
