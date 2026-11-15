# Target: SwitchBot BLE Smart Actuator/Sensor

## Target metadata
- target_id: switchbot-ble
- app package_id(s): com.theswitchbot.switchbot
- device class: BLE smart actuator/sensor (multiple device types)
- transport(s): BLE
- local-only viability: high — purely BLE; official BLE API published by manufacturer

## Known facts (verified from RE sources)
- SwitchBot product family (source: OpenWonderLabs/SwitchBotAPI-BLE — official manufacturer BLE API)
- Price: $15-40 depending on device
- VERIFIED: Service UUID: `cba20d00-224d-11e6-9fb8-0002a5d5c51b`
- VERIFIED: RX (notify) char: `cba20002-224d-11e6-9fb8-0002a5d5c51b`
- VERIFIED: TX (write) char: `cba20003-224d-11e6-9fb8-0002a5d5c51b`
- VERIFIED: Company ID: 0x0969 (new, v6.4+) / 0x0059 (old)
- VERIFIED: Service data UUID: 0xFD3D (new) / 0x000D (old)
- VERIFIED: Magic number: 0x57 in command frames
- VERIFIED: MTU: 1-20 bytes
- VERIFIED: Response codes: OK=0x01, ERROR=0x02, BUSY=0x03, etc.
- VERIFIED: Device type codes in scan response byte 0 (bits 6:0):
  - Bot=0x48, Meter=0x54, Humidifier=0x65, Curtain=0x63, Curtain3=0x7B
  - Motion Sensor=0x73, Contact Sensor=0x64, Color Bulb=0x75
  - LED Strip=0x72, Smart Lock=0x6F, Plug Mini=0x67, Meter Plus=0x69
- TBD — needs verification: BLE advertised names ("WoHand", "WoCurtain" etc. are speculative)
- Existing RE: OpenWonderLabs/SwitchBotAPI-BLE (official), Danielhiversen/pySwitchbot

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — speculative; use device type byte in service data instead
  - service UUIDs: `cba20d00-224d-11e6-9fb8-0002a5d5c51b` (VERIFIED)
  - service data UUID: 0xFD3D (VERIFIED)
  - company ID: 0x0969 in manufacturer data (VERIFIED)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Bot presses physical buttons — ensure target button is non-critical.
- Curtain motor — low force.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.theswitchbot.switchbot.
3) Static: review official SwitchBotAPI-BLE docs for per-device protocol.
4) Dynamic: record one "connect + press button" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: some devices may require password (TBD per device type)
- Session state machine: connect -> write to TX char with magic 0x57 -> receive response on RX char
- Commands: device-specific, documented per type in official API repo (VERIFIED)
- Payload encoding: binary, magic byte 0x57 prefix, 1-20 byte frames (VERIFIED)
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan using service data UUID 0xFD3D + type code
- Core controls (MVP): Bot press, Curtain open/close, Meter read
- Power / brightness / modes / uploads: Bot hold/press mode, Curtain position %
- Error handling and recovery: reconnect, handle BUSY response
- Settings persistence: device stores settings internally

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/switchbot-ble.md

## References (URLs only)
- https://github.com/OpenWonderLabs/SwitchBotAPI-BLE
- https://github.com/Danielhiversen/pySwitchbot
