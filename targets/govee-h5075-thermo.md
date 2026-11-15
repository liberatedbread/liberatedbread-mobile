# Target: Govee H5075 BLE Thermometer/Hygrometer

## Target metadata
- target_id: govee-h5075-thermo
- app package_id(s): com.govee.home
- device class: BLE thermometer/hygrometer
- transport(s): BLE (advertisement broadcast)
- local-only viability: high — broadcasts temp/humidity via BLE advertisements

## Known facts (verified from RE sources)
- Govee H5074/H5075 temperature and humidity sensor (source: wcbonner/GoveeBTTempLogger)
- Also supported: H5072, H5100, H5101, H5104, H5105, H5110, H5174, H5177, H5179 (VERIFIED)
- H5181-H5183 are meat thermometers — different protocol (UUIDs 5182/5183)
- Price: $10-15
- VERIFIED: Broadcasts data via BLE manufacturer-specific advertisement data
- VERIFIED: 128-bit custom service UUID: `494e5445-4c4c-495f-524f-434b535f4857` (ASCII for "INTELLI_ROCKS_HW")
- VERIFIED: Standard advertisement UUID: 0x88EC / 0xEC88
- VERIFIED: Historical data download (20 days; H5177 stores 1 month)
- VERIFIED: History download write char: `494e5445-4c4c-495f-524f-434b535f2012`, notify response: `...2013`
- NOTE: H5100/H5105 need LE_RANDOM_ADDRESS — address behavior varies by model
- Existing RE: github.com/wcbonner/GoveeBTTempLogger, github.com/Thrilleratplay/GoveeWatcher

## Device discovery signals
- BLE:
  - advertised name patterns: "GVH5075_XXXX", "GVH5074_XXXX", "Govee_H5074_XXXX", "GVH5174_XXXX" (VERIFIED)
  - service UUIDs: 0x88EC in advertisement; custom `494e5445-4c4c-495f-524f-434b535f4857` (VERIFIED)
  - address behavior: public for most; H5100/H5105 need LE_RANDOM_ADDRESS (VERIFIED)

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Passive sensor — no actuation risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.govee.home.
3) Static: grep for UUIDs/endpoints + identify advertisement data format.
4) Dynamic: capture BLE advertisements with btmon or nRF Connect.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: none — passive advertisement broadcast (VERIFIED)
- Session state machine: no connection needed for live; connection needed for history download
- Commands: N/A for live; history requires write to `...2012` char (VERIFIED)
- Payload encoding: TBD — exact byte layout of temp/humidity in manufacturer data needs mapping
- Timing constraints: TBD — advertisement interval not confirmed

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for GVH5075 name pattern
- Core controls (MVP): read temperature, read humidity
- Power / brightness / modes / uploads: historical data download (20 days)
- Error handling and recovery: handle missed advertisements
- Settings persistence: N/A

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/govee-h5075-thermo.md

## References (URLs only)
- https://github.com/wcbonner/GoveeBTTempLogger
- https://github.com/Thrilleratplay/GoveeWatcher
- https://github.com/Bluetooth-Devices/govee-ble
- https://github.com/egold555/Govee-Reverse-Engineering
