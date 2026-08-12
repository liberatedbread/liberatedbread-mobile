# Davis WeatherLink Live (6100) — Local API Research Notes

## What it is
Davis Instruments (Hayward, CA) WeatherLink Live 6100: Wi-Fi/Ethernet data hub
that receives Davis RF transmitters (Vantage Pro2/Vue ISS, sensor transmitters,
AirLink) and normally uploads to weatherlink.com. **Davis AirLink 7210 air
quality monitor exposes the same local API.**

## Local protocol — vendor-documented, no auth
Official docs: [weatherlink.github.io/weatherlink-live-local-api](https://weatherlink.github.io/weatherlink-live-local-api/)
(source: github.com/weatherlink/weatherlink-live-local-api).

- `GET http://<ip>:80/v1/current_conditions` → JSON: all tracked transmitters
  (ISS temp/hum/wind/rain/solar/UV, leaf/soil, plus hub-internal barometer,
  inside temp/hum). Pollable every 10 s. Fields carry `lsid`, `txid`,
  `data_structure_type` (1=ISS, 2=leaf/soil, 3=bar, 4=temp/hum).
- `GET /v1/real_time?duration=<sec>` → starts a **UDP broadcast on port 22222**
  with 2.5 s wind/rain rapid updates for up to 86400 s; response reports
  `broadcast_port` and `duration`.
- No API key, no token, no cloud session for either endpoint. Error model
  documented (400/404/409/414 JSON error objects).
- Device discovery documented in the same repo (find WLL on LAN; unit hostname
  pattern `weatherlinklive-XXXXXX` visible in DHCP/Bonjour).

## Cloud dependency
- Local API: none. Works offline once the unit is on the LAN.
- Initial setup: WeatherLink app pairs WLL to weatherlink.com account; Wi-Fi
  can also be configured from the unit's own web interface (built-in HTTP
  server) — the local API itself never checks credentials.
- Caveat: Davis app/account ecosystem is healthy; even if weatherlink.com
  died, `/v1/current_conditions` is implemented in firmware.

## Community implementations
- [ryan-lang/homeassistant-davis-local](https://github.com/ryan-lang/homeassistant-davis-local) (HACS, polls `/v1/current_conditions`)
- WeeWX `WeatherLinkLive` driver, HomeSeer AKWeather plugin, assorted
  Node-RED/gists.
- Older hardware note: WeatherLink IP 6555 (Vantage consoles) had NO local API;
  for those the local Wi-Fi path is the third-party Belfryboy WiFiLogger —
  see `belfryboy-wifilogger.md`.

## Company status (checked 2026-08-07)
Active. Davis Instruments (owned by AEM since 2021) still sells WeatherLink
Live and maintains the local-api GitHub repo.

## APK
Not needed — vendor-published API docs. (WeatherLink app `com.davisnet.…` on
Play if app-behavior detail is ever wanted.)

## Rating
**Confirmed** — vendor-documented local API with multiple implementations.

## Spec-work notes
- Transcribe current_conditions record types 1–4 and the real_time handshake
  (including 409 "No ISS Transmitters" case and duration-extension semantics).
- Units are imperial (°F, mph, inHg, rain counts); rain counts need
  `rain_size` decoding (1=0.01", 2=0.2 mm, 3=0.1 mm, 4=0.001").
