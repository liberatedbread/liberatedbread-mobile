# De'Longhi Pinguino portable AC — BLE remote emulation — target spec starter

## Target metadata
- target_id: delonghi-pinguino-ble-remote
- app package_id(s): none — these units ship with a BLE remote, not an app
- device class: portable air conditioner whose remote is a BLE HID
  peripheral; models not enumerated by the source (owner reports requested)
- transport(s): BLE — **the air conditioner is the central** and the remote is
  the peripheral, so a replacement is a peripheral emulator, not a client
- local-only viability: **high** (no cloud exists) but **inverted shape**:
  this is the first target where the thing to spec is what a device
  *expects* from a peripheral — advertising, scan response, GATT/HID layout,
  report format and SMP pairing/bonding behaviour.

## Known facts (public; HA community 2026-06, MIT)
- A bridge (ESP32-S3 for Wi-Fi/MQTT/HTTP + nRF52840 running Zephyr as the
  BLE emulator) impersonates the original remote well enough that the AC
  bonds to it; the ESP32's own radio could not pass the AC's pairing gate.
- Pairing: with no bond stored the emulator advertises in pairing mode
  (limited discoverable) with no button press; on the AC, with the unit
  plugged in but off, hold MODE about 10 s until the display dot blinks
  fast; the two bond within about 60 s.
- Buttons reproduced: power, up, down, mode, eco, timer, fan, silent, flap.
- The repo carries the reverse-engineering notes (identity, advertising,
  GATT, button reports, link-layer pairing gate, SMP) and sniffer tooling;
  the thread itself gives no UUIDs or frames.
- Sources: [HA thread](https://community.home-assistant.io/t/hardware-compatibility-de-longhi-pinguino-ble-remote-bridge-with-esp32-s3-nrf52840/1012791)
  (2026-06-04) · [bdherouville/pinguino-ha-remote](https://github.com/bdherouville/pinguino-ha-remote) (MIT).

## Device discovery signals
- BLE: the AC scans; the remote advertises. Original remote's advertised name
  TBD (the emulator advertises as "Ganymede", which may or may not be the
  original's name). HID-over-GATT service expected.

## Threat model + guardrails
- Owned units only. An emulated remote can switch a heater/compressor on
  unattended: no schedules beyond what the physical remote offers.
- Schema question before any spec: `device.pairing` and `services` describe a
  peripheral *we connect to*; a peripheral *we emulate* needs a new block.
  Propose it in docs/contributing/spec-evolution.md first.

## First experiments
1) Read the repo's protocol notes; list UUIDs, report descriptor, SMP
   parameters (IO capability, bonding flags, key sizes the AC insists on).
2) Ask the author which Pinguino models (PAC EX/EL/AN series?) have the BLE
   remote; the thread has none yet.

## References (URLs only)
- https://community.home-assistant.io/t/hardware-compatibility-de-longhi-pinguino-ble-remote-bridge-with-esp32-s3-nrf52840/1012791
- https://github.com/bdherouville/pinguino-ha-remote
