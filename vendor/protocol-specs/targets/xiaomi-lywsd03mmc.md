# Target: Xiaomi Mijia LYWSD03MMC BLE Thermometer/Hygrometer

## Target metadata
- target_id: xiaomi-lywsd03mmc
- app package_id(s): com.xiaomi.smarthome
- device class: BLE thermometer/hygrometer
- transport(s): BLE
- local-only viability: high — custom firmware enables direct BLE advertisement of data; OTA flashable from browser

## Known facts (verified from RE sources)
- Xiaomi Mijia LYWSD03MMC (source: pvvx/ATC_MiThermometer)
- Price: $4-6
- VERIFIED: Telink TLSR8251 SoC, 6 hardware versions: B1.4, B1.5, B1.6, B1.7, B1.9, B2.0
- VERIFIED: Custom firmware OTA flashable from web browser
- VERIFIED: 5 advertisement formats: Xiaomi (MiBeacon), ATC, Custom, BTHome v2, HA BLE
- VERIFIED: MiBeacon UUID 0xFE95 (stock firmware, encrypted)
- VERIFIED: Custom firmware broadcasts unencrypted temp/humidity/battery in 0.01 unit precision
- VERIFIED: Can be converted to Zigbee via z03mmc firmware
- VERIFIED: BLE 5.0+ with LE Long Range (Coded PHY S=8)
- VERIFIED: Also supports: MHO-C401/C401N, MJWSD05MMC, Qingping CGG1-M/CGDK2, Tuya TH03/ZTH01/02/05
- E-ink display, CR2032 battery, lasts 6-12 months
- Existing RE: github.com/pvvx/ATC_MiThermometer, github.com/devbis/z03mmc

## Device discovery signals
- BLE:
  - advertised name patterns: "LYWSD03MMC" (stock), "ATC_XXXXXX" (custom firmware) — VERIFIED
  - service UUIDs: Xiaomi MiBeacon 0xFE95 (stock) — VERIFIED
  - address behavior: public (custom firmware), random (stock) — VERIFIED

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Passive sensor — no actuation risk.
- Custom firmware flashing is reversible.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.xiaomi.smarthome.
3) Static: grep for MiBeacon protocol UUIDs (0xFE95).
4) Dynamic: capture BLE advertisements with stock and custom firmware.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: stock requires Xiaomi cloud; custom: none (VERIFIED)
- Session state machine: passive advertisement broadcast (VERIFIED)
- Commands: N/A (read-only sensor)
- Payload encoding: stock: MiBeacon encrypted; custom: plain temp/humidity/battery (VERIFIED)
- Timing constraints: advertisement interval configurable in custom firmware

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for LYWSD03MMC name
- Core controls (MVP): read temperature, read humidity, read battery
- Power / brightness / modes / uploads: N/A
- Error handling and recovery: handle missed advertisements
- Settings persistence: N/A

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/xiaomi-lywsd03mmc.md

## References (URLs only)
- https://github.com/pvvx/ATC_MiThermometer
- https://github.com/devbis/z03mmc
- https://home-is-where-you-hang-your-hack.github.io/ble_monitor/MiBeacon_protocol
