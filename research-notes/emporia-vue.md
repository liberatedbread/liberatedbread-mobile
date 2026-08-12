# Emporia Vue (Gen 2 / Gen 3) — stock DUD, reflash rescue — Research Notes

## Verdict on stock firmware
**Cloud-only.** Verified 2026-08-07. Factory firmware reports exclusively to
Emporia's cloud (MQTT/TLS to AWS); there is no LAN API on any Vue generation.
HA's `emporia_vue` integration is cloud_polling (pyemvue). Emporia (active
company) has never published a local interface.

## The rescue: ESPHome reflash (confirmed community path)
All Vue units are ESP32-based. The `emporia-vue-local` project maintains an
ESPHome fork that replaces the firmware and makes the unit fully local:

- **Vue 2** (ESP32-WROOM): mature support. Flash over UART — open the case,
  connect a USB-serial adapter to the ESP32 header pads (documented pinout;
  board schematics in emporia-vue-local/emporia-vue2-reversing, KiCad).
  Custom `emporia_vue` component reads the measurement MCU over I2C; mains
  and 16 branch channels come out as local sensors.
  (g3gg0.de writeup, 2023-06; flaviut gist, updated 2025-07.)
- **Vue 3** (ESP32): supported on the same fork with `variant: vue3`;
  GPIO/pinout differences — working configs shared in repo discussions
  (#306, #367; still rough edges per #349/#376 through 2026-01).
- After flashing: ESPHome native API to Home Assistant and/or MQTT — no
  cloud, OTA-updatable, standard ESPHome stack.

## Cloud requirement
Stock: total (account mandatory; device is a brick without it).
After reflash: none. Reflash itself is one-time, local, reversible only by
keeping a stock firmware backup (dump before flashing!).

## Why this note exists despite "dud"
The stock protocol fails the repo's local-only bar, but this is one of the
most common whole-home monitors in the field and the reflash path is
well-trodden — the value is documenting the rescue precisely.

## Open questions
1. UART pad pinout + flashing steps per generation (Vue 2 documented; Vue 3
   pinout from discussions — consolidate).
2. Stock firmware dump/restore procedure for rollback.
3. I2C register map of the measurement MCU (in the esphome fork source) —
   transcribe into spec.

## Safety
MEDIUM-HIGH: the unit lives inside the breaker panel wired across phases;
opening/flashing should be done disconnected from mains. Measurement-only.
