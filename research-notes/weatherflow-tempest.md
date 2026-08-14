# WeatherFlow Tempest — Local UDP API Research Notes

## What it is
WeatherFlow-Tempest (Austin, TX) all-in-one personal weather station: Tempest
sensor unit (haptic rain, sonic wind, pressure, temp/hum, light/UV, lightning)
talks sub-GHz RF to an indoor Wi-Fi hub, which forwards to the vendor cloud.

## Local protocol — vendor-documented UDP broadcast
- Hub broadcasts JSON datagrams to LAN broadcast address on **UDP 50222**.
- Officially documented: [Tempest UDP Reference v143](https://weatherflow.github.io/Tempest/api/udp/v143/)
  (vendor GitHub Pages). Message types: `evt_precip` (rain start),
  `evt_strike` (lightning), `rapid_wind` (3-second wind), `obs_air`/`obs_sky`/
  `obs_st` (1-min observations incl. battery, RSSI, firmware rev),
  `device_status`, `hub_status`.
- No auth, no token, no subscription: any host on the same broadcast domain
  listening on 50222 gets the data. Works with internet down.
- Implementations: Home Assistant **core** `weatherflow` integration
  (`iot_class: local_push`, added 2024), [briis/hass-weatherflow2mqtt](https://github.com/briis/hass-weatherflow2mqtt)
  (now archived in favor of core), WeatherFlow PiConsole ("UDP only mode …
  requires no connection to the internet once installation is complete"),
  Homebridge/Indigo/Homey plugins.
- Also local: BLE on the hub/sensor for provisioning (and diagnostics);
  BLE observation readout is NOT exposed — UDP is the local data path.

## Cloud dependency — one-time provisioning only
- First-time setup requires the Tempest app (iOS/Android) with a vendor
  account: station is claimed over BLE and Wi-Fi credentials are pushed.
  No documented account-free provisioning path; BLE provisioning RE is the
  theoretical workaround (app uses standard BLE GATT for setup).
- After provisioning, UDP 50222 broadcast is unconditional — cloud outage or
  account deletion does not stop local data (per PiConsole docs and HA core
  integration behavior).
- Cloud-only extras: forecast, history beyond memory, calibration services.

## Company status (checked 2026-08-07)
Active. WeatherFlow-Tempest, Inc. spun off from WeatherFlow; running a Wefunder
raise started 2025-12 (valuation $73.9M, "150,000+ paying customers",
[KingsCrowd](https://kingscrowd.com/weatherflow-tempest-on-wefunder-2025/)).
tempest.earth store and community forum live. Risk note: hardware is
single-source and the UDP API is a vendor promise, not firmware-guaranteed
forever — but it has survived every firmware rev to date (v143+ documented).

## APK
Not needed — UDP format is vendor-documented; HA core integration is the
reference implementation. (Tempest app package `com.weatherflow.tempest` if
BLE provisioning RE is ever attempted.)

## Rating
**Confirmed** — vendor-documented local API + HA core local integration.

## Spec-work notes
- Transcribe the v143 message table (`obs_st` field order/units is the core of
  it: epoch, wind lull/avg/gust, direction, sample interval, pressure, temp,
  hum, lux, UV, solar rad, rain mm, precip type, lightning dist/count, battery,
  report interval, RSSI fields).
- Note multi-device case (legacy AIR + SKY emit `obs_air`/`obs_sky`).
