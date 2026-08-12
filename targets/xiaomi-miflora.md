# Target: Xiaomi Mi Flora / Flower Care Plant Sensor

## Target metadata
- target_id: xiaomi-miflora
- app package_id(s): com.huahuacaocao.flowercare
- device class: plant/soil sensor (moisture, temperature, light, soil fertility)
- transport(s): BLE
- local-only viability: high — purely BLE, coin cell powered, ~1 year battery life

## Known facts (verified from RE sources)
- Xiaomi Mi Flora / Flower Care plant sensor
- Price: $12-17
- VERIFIED: Measures soil moisture, temperature, light intensity, soil fertility/conductivity
- VERIFIED: Coin cell (CR2032) powered, ~1 year battery life
- VERIFIED: Advertised name "Flower care" / "Flower mate" (community documentation)
- VERIFIED (from basnijholt/miflora source code miflora_poller.py): write 0xA01F to handle 0x33 (`_HANDLE_WRITE_MODE_CHANGE`) for real-time mode, read from handle 0x35 (`_HANDLE_READ_SENSOR_DATA`), firmware/battery from handle 0x38 (`_HANDLE_READ_VERSION_BATTERY`)
- VERIFIED: Additional handles in source: device time 0x41 (`_HANDLE_DEVICE_TIME`), history control 0x3E (`_HANDLE_HISTORY_CONTROL`), history read 0x3C (`_HANDLE_HISTORY_READ`)
- VERIFIED: Writing 0xFDFF to handle 0x33 makes device blink top LED once
- Community-documented: Payload encoding binary LE — temp (C x 10), moisture (%), light (lux), fertility (uS/cm)
- Existing RE: github.com/basnijholt/miflora, github.com/sidddy/flora, github.com/vrachieru/xiaomi-flower-care-api

## Device discovery signals
- BLE:
  - advertised name patterns: "Flower care", "Flower mate" (community-documented)
  - service UUIDs: TBD — needs confirmation from source code
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Passive sensor — no actuation risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.huahuacaocao.flowercare.
3) Static: grep for GATT handles/UUIDs + data format.
4) Dynamic: capture BLE read of sensor data with btmon.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: TBD — none for reading (community-documented), may need bonding for firmware update
- Session state machine: connect -> write mode switch -> read data -> disconnect (community-documented)
- Commands: enable real-time (write 0xA01F to handle 0x33), read sensors (handle 0x35), read FW/battery (handle 0x38) — VERIFIED from miflora_poller.py source
- Payload encoding: binary LE integers (community-documented)
- Timing constraints: TBD — real-time mode may timeout

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for "Flower care" name
- Core controls (MVP): read all 4 sensor values, read battery level
- Power / brightness / modes / uploads: N/A
- Error handling and recovery: handle connection timeouts, retry reads
- Settings persistence: N/A (read-only sensor)

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/xiaomi-miflora.md

## References (URLs only)
- https://github.com/basnijholt/miflora
- https://github.com/sidddy/flora
- https://github.com/vrachieru/xiaomi-flower-care-api
