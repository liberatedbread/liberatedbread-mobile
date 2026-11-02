# myCOOLMAN MCMR portable fridge/freezers — target spec starter

## Target metadata
- target_id: mycoolman-mcmr-fridge
- app package_id(s): TBD ("myCOOLMAN" on Google Play / App Store; retailer
  copy says to search the store for "mycoolman")
- device class: 12/24 V compressor portable fridge-freezer (MCMR43 confirmed;
  MCMR60 single-zone and MCMR38DZ / MCMR55DZ / MCMR78DZ dual-zone untested)
- transport(s): BLE GATT, phone-direct, no cloud
- local-only viability: **high** — the vendor app is already local-only;
  a community HA integration (MIT) controls a real MCMR43 and is in use.

## Known facts (public; HA community, 2026-07)
- Status arrives as a 22-byte frame pushed by GATT notification; one byte is
  a bitmask carrying the LED, buzzer and auto-dim settings. Input voltage is
  believed to be tenths of a volt — **unverified against a meter**.
- Set-point range in the vendor app: −22 °C to +10 °C; turbo (max-cool) mode;
  battery-protection level (low / medium / high); °C/°F display; fault flags.
- Opcodes were recovered by starting from an earlier open-source client
  ([luoxs/Mycoolman](https://github.com/luoxs/Mycoolman)) and diffing the
  status frame after each raw write to the hardware.
- Dual-zone models expose extra freezer-zone fields the integration does not
  yet decode.
- Sources: [HA thread](https://community.home-assistant.io/t/custom-integration-mycoolman-mcmr-fridge-freezer-local-ble-control/1016431)
  (2026-07-07) · [HeapsGoodTom/mycoolman-ha](https://github.com/HeapsGoodTom/mycoolman-ha) (MIT).
- Many "Alpicool"-style compressor fridges from the same Chinese OEMs share a
  BLE protocol family; whether MCMR is one of them is worth checking before
  writing a fresh spec (search the repo for alpicool first).

## Device discovery signals
- BLE: name pattern and service UUIDs not published in the sources — read the
  integration's source or scan. Address behaviour unknown.
- Wi-Fi: none.

## Threat model + guardrails
- Owned units only. A set-point write that defrosts a freezer spoils food:
  mark the temperature set-point as needing confirmation in a client, and
  cap it to the vendor range.

## First experiments
1) Read the integration source for UUIDs, the 22-byte layout and opcodes.
2) Confirm the voltage scaling against a multimeter on the DC input.
3) One HCI capture of connect + set temperature + read status.

## Control surface inventory (replacement app MVP)
- power · set-point (per zone) · turbo · battery-protection level · live
  temperature · input voltage · fault flags · LED/buzzer/auto-dim toggles

## References (URLs only)
- https://community.home-assistant.io/t/custom-integration-mycoolman-mcmr-fridge-freezer-local-ble-control/1016431
- https://github.com/HeapsGoodTom/mycoolman-ha
- https://github.com/luoxs/Mycoolman
