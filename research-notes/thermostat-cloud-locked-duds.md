# Cloud-Locked Thermostat Leads — Verified Rejections (Nest / Honeywell TCC / Netatmo)

Each lead below was checked for a genuine local Wi-Fi control path (no
cloud account, no MITM) on 2026-08-07. All are **rejected** as repo spec
targets; reasons and narrow exceptions noted.

## Google Nest — REJECTED (cloud-locked, confirmed)
- No local API on any Nest Learning Thermostat or Nest Thermostat E.
  Programmatic control is Google **SDM API** = cloud-only (OAuth + Pub/Sub;
  $5 one-time developer fee). "There is no way to control a supported Nest
  device without an Internet connection… even if the HA server and the Nest
  are on the same subnet" (karlquinsland.com, 2022-04-23).
- Gen 1 & 2 Learning Thermostats lost all support/connectivity
  **2025-10-25** (Hubitat/openHAB notices, 2025-04).
- **Narrow exception:** the **Nest Thermostat (2020)** received **Matter
  over Wi-Fi** via OTA from 2023-04-18 (The Verge, 2023-04-18) — local
  control via a Matter controller is then possible, but commissioning
  requires the Google Home app + Google account, and the unit is useless
  without it. Not a local-API rescue; excluded per repo's no-cloud-account
  bar. No HomeKit; no HAP.

## Honeywell Home / Resideo Wi-Fi (TCC line: RTH9580/9585WF, TH9320WF "Wi-Fi
9000", RedLINK via THM6000R gateway) — REJECTED
- All control flows through **mytotalconnectcomfort.com** (TCC) cloud;
  HA's `honeywell` integration is cloud polling (accessed 2026-08-07). No
  documented local endpoint on the thermostats or the RedLINK Internet
  Gateway; no community local implementation exists.
- **Narrow exception:** T9/T10 and Lyric Round support **HomeKit**, giving
  HAP-local control of the basics — but TH9320WF/RTH958x (the named leads)
  have no HomeKit and no local path. If a HomeKit-only T9/T10 note is
  wanted later it would mirror the ecobee-thermostat note.

## Netatmo Smart Thermostat + radiator valves — REJECTED
- Official API is cloud-only (api.netatmo.com; HA integration is
  cloud_polling). Thermostat↔relay link is proprietary 868 MHz, not Wi-Fi.
- **Narrow exceptions:** HomeKit pairing exposes only basic control (set
  temp, read temp, display unit — HA community #669150, 2024-01), and
  newer firmware advertises Matter per 2026 retailer listings; both still
  require a Netatmo account + app for provisioning. Fails the
  no-cloud-account bar.

## Also checked
- **Sensibo Sky/Air** — cloud-only API; rejected.
- **Mitsubishi Kumo Cloud (PAC-USWHS002/003)** — cloud-only for the
  official module; local control exists only via third-party hardware
  (ESPhome MHI-AC-Ctrl, ClimaControl), which is a hardware-mod path, not a
  protocol spec. Rejected for this category.
