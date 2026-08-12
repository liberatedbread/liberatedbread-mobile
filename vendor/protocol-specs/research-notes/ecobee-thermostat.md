# Ecobee Smart Thermostats (ecobee3/3 lite/4, SmartThermostat, Enhanced/Premium) — Research Notes

## What it is
Ecobee (Toronto; acquired by **Generac** in 2021) consumer thermostats.
Company active; no native local HTTP API — the only local path is
**Apple HomeKit (HAP)**.

## Local control: HomeKit only (confirmed)
- Every HomeKit-capable ecobee (ecobee3 lite, ecobee4, SmartThermostat w/
  voice, Enhanced, Premium, 2025 "Essential") exposes HAP over Wi-Fi:
  mDNS `_hap._tcp`, local pairing with the 8-digit code shown under
  Settings → HomeKit.
- Home Assistant `homekit_controller` gives **fully local** control —
  current/target temp, mode (off/heat/cool/auto), humidity. No ecobee
  account needed at pairing time if you can still reach the pairing code
  on the device screen; must first **remove the thermostat from any Apple
  Home** (Hubitat/HA community guides, 2023–2024).
- Limitations vs cloud API: no remote sensor detail beyond occupancy
  (SmartSensors pair to the stat over 915 MHz proprietary, not exposed via
  HAP except basic occupancy), limited fan/ventilator/schedule control,
  no eco+ features.

## Cloud status and deprecation warnings
- Ecobee **deprecated the first-gen Smart/EMS thermostats 2024-07-31** —
  remote control/data storage stopped; local HomeKit on those gen-1/2 units
  is unreliable or absent (innovo.net wiki, 2025-06).
- Ecobee stopped issuing new developer API keys 2024-03-28 — the official
  cloud API is in maintenance; makes the local path more valuable.

## Cloud steps required
- Initial setup normally uses the ecobee app + account. The HomeKit
  pairing code is on-device, so local pairing works without the cloud
  account afterwards; a full offline cold-start (fresh unit, no ecobee
  account) is not documented — treat initial provisioning as app-assisted.
- HA migration guide: "Migrate from Ecobee Cloud Integration to Local
  HomeKit Controller" (community.home-assistant.io, 2023-04-07).

## Rating
Confirmed for local **basic** control via HAP (multiple community
implementations). Not a full local API — document as HAP-profile device,
not as a custom protocol target.

## Sources
- wiki.innovo.net/en/ecobee (2025-06-09): gen-1 deprecation, HomeKit flow
- HA community #491319 (2023-04-07) and #386116 (2022-01-30): local vs cloud
- github.com/home-assistant/core#54094 (2021-08-05): ecobee3 lite w/o account
- MacRumors forum (2025-01-09): ecobee Essential HomeKit launch
