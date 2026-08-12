# Ecowitt Wi-Fi Gateways (GW1000/GW1100/GW1200/GW2000/GW3000) — Local API Research Notes

## What it is
Ecowitt (Fine Offset, Shenzhen) sells Wi-Fi gateway pucks and display consoles that
aggregate 433/868 MHz sensor data (WS69/WS80/WS90 arrays, WH31/WH51 soil, WN34,
WH45 air quality, lightning, etc.) onto a LAN. Same hardware is sold as Froggit
(DP1500 = GW1100), Sainlogic, Bresser (recent models), Ecowitt HP2551/HP2560
consoles, and re-branded Ambient Weather consoles (WS-2000/WS-5000 — see
`ambient-weather-ws2xxx.md`).

## Why this is the gold standard for local
Three independent, vendor-shipped local paths, no cloud account needed for any:

### 1. TCP command API on port 45000 (officially documented)
- Binary request/response protocol; vendor PDF "WN1900 GW1000,1100 WH2680,2650
  telnet v1.6.4" published at `osswww.ecowitt.net` (2022-04); community has v1.6.9
  ([wxforum.org wiki thread, 2022-09](https://www.wxforum.org/index.php?topic=40730.0)).
- Functions: read live sensor data, sensor registry + battery, firmware/system
  info, calibration, rain totals, set custom-server config, reboot.
- Implementations: `weewx-gw1000` driver (WeeWX),
  [bmdevx/ecowitt-gw1000](https://github.com/bmdevx/ecowitt-gw1000) (Node),
  [bmrzycki/gw1000-http](https://github.com/bmrzycki/gw1000-http) (Python HTTP
  front-end), FOSHKplugin.

### 2. HTTP JSON endpoints on port 80 (newer firmware, GW1100/GW2000/GW3000)
The gateway's built-in web UI is backed by unauthenticated GET endpoints:
- `/get_livedata_info` — all live sensor values as JSON
- `/get_sensors_info?page=1` (and page=2) — registered sensors, battery, signal
- `/get_ws_settings`, `/get_units_info`, `/get_calibration`, `/get_rain_totals`,
  `/get_device_info`, `/get_piezo_rain` (WS90 piezo)
- Sources: [meteodrenthe.nl walkthrough (2023-02)](https://blog.meteodrenthe.nl/2023/02/03/how-to-use-the-ecowitt-gateway-gw1000-gw1100-local-api/),
  [Ecowitt forum (2022-04)](https://www.ecowitt.com/shop/forum/forumDetails/496),
  [mplogas/ecowitt-controller](https://github.com/mplogas/ecowitt-controller).

### 3. Custom-server push (Ecowitt or Wunderground protocol)
- Configured locally via gateway web UI or the WS View Plus / Ecowitt app:
  user supplies LAN IP/hostname, port, path, interval, protocol type
  ("Ecowitt" or "Wunderground"); gateway then POSTs/GETs readings to that host.
- Home Assistant core `ecowitt` integration is `iot_class: local_push` built on
  exactly this (device posts to `http://<HA>:4199/<webhook>`).

## Cloud dependency
None for any of the three paths. ecowitt.net cloud upload is optional and
independent. WS View Plus app does local discovery/config without an account;
the newer Ecowitt app wants an account only for cloud features.

## APK
Not needed — protocol is vendor-documented (PDF) and implemented by multiple
open-source projects. (WS View Plus = `com.ost.wsview`; Ecowitt app =
`com.ecowitt.ecowitt`, fetchable if a spec ever needs app-behavior details.)

## Company status (checked 2026-08-07)
Active. Ecowitt keeps shipping gateways and publishing firmware; wxforum wiki
thread shows firmware releases into 2024+. Fine Offset clone ecosystem is the
largest in consumer PWS hardware.

## Rating
**Confirmed** — vendor-documented protocol + multiple mature community
implementations + HA core local integration.

## Spec-work notes
- Transcribe the 45000 command table (from the vendor PDF, in own words) and the
  HTTP GET endpoints; cover both GW1000-era (TCP only) and GW2000-era (TCP+HTTP).
- Custom-server Ecowitt protocol = HTTP POST form fields (`PASSKEY`,
  `stationtype`, `dateutc`, `tempinf`, ...); Wunderground mode = HTTP GET query.
