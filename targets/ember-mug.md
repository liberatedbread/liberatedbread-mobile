# Ember Mug family — target spec starter

## Target metadata
- target_id: ember-mug
- app package_id(s): com.embertech
- device class: temperature-controlled mug / drinkware
- transport(s): Bluetooth (BLE)
- local-only viability: high (core temperature control is BLE-local; cloud telemetry to collector.embertech.com is optional)

## Known facts (public)
- Product line includes Ember Mug 2 (10 oz / 14 oz), Travel Mug 2 / 2+, Cup (6 oz), Tumbler.
- App controls target temperature, presets, LED color, and firmware updates.
- Community RE exists: orlopau/ember-mug (protocol docs from APK decompilation), sopelj/python-ember-mug (Python library), Home Assistant integration (sopelj/hass-ember-mug-component).
- Telemetry sent to https://collector.embertech.com (can be blocked without affecting BLE control).

## Device discovery signals (hypotheses)
- BLE advertised name patterns: "Ember Ceramic Mug", "Ember Mug", "Ember Travel Mug", or model-specific strings
- Service UUIDs: custom 128-bit service UUID fc543622-236c-4c94-8fa9-944a3e5353fa (per community RE)
- Address behavior: unknown (discover via scan)

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Temperature range must respect manufacturer safety limits.

## First experiments
1) Run ./scripts/detect_devices.sh with the Ember Mug 2 powered on.
2) Static APK scan (com.embertech):
   - search for UUID literals and GATT service/characteristic references
   - search for "ember", "temperature", "battery", "ceramic", "travel"
   - identify BLE command/response formats
3) Cross-reference findings with orlopau/ember-mug protocol documentation.
4) HCI snoop: connect in app, change target temperature, observe BLE traffic.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: likely "just works" BLE pairing
- Session state machine: connect → discover services → read/write characteristics
- Commands: set target temp, read current temp, read battery, set LED color, read device name
- Payload encoding: little-endian temperature values (likely in 0.01°C or 0.5°F increments)
- Timing constraints: unknown

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX
- Set target temperature
- Read current temperature
- Read battery level
- Set LED color
- Read device info (name, firmware version, serial)
- Temperature presets

## Evidence checklist
- APK hashes + version code
- HCI snoop log
- Screenshots (optional)

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/ember-mug.md
- device-specs/devices/ember-mug.yaml

## References
- https://ember.com/products/ember-mug-2
- https://play.google.com/store/apps/details?id=com.embertech
- https://github.com/orlopau/ember-mug
- https://github.com/sopelj/python-ember-mug
- https://github.com/sopelj/hass-ember-mug-component
