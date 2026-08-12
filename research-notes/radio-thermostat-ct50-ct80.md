# Radio Thermostat CT30/CT50/CT80 (3M Filtrete 3M-50) — Research Notes

## What it is
Wi-Fi thermostats by Radio Thermostat Company of America (RTCOA), sold as
CT30, CT50, CT80 and the 3M Filtrete 3M-50 rebadge; the same platform shipped
inside Vivint and some utility-program thermostats. Wi-Fi (and Z-Wave) come
on pluggable USNAP radio modules. Units are plentiful on the used market.

## Why it's abandoned — and why the local API is the rescue
- RTCOA's cloud is **dead**: owners received email (2022-12) that "On
  May 15, 2023, the Radio Thermostat mobile app is being discontinued and
  you will no longer be able to control your thermostat with internet
  connected devices" — support contact given as `rtcoa-support@energyhub.com`
  ([Hubitat thread, 2022-12-21](https://community.hubitat.com/t/radio-thermostat-mobile-app/108118)).
- Company status: RTCOA was folded into **EnergyHub**, an independent
  subsidiary of **Alarm.com** (EnergyHub "About" boilerplate, 2024; the
  Filtrete/RTCOA partnership dates to ~2012). `radiothermostat.com` now
  returns a Wix 404 (checked 2026-08-07). The mobile app is delisted —
  apkeep finds no Play/APKPure package (checked 2026-08-07).
- The **local REST API keeps working** with the cloud gone; it never needed
  the cloud to function.

## Local protocol (vendor-documented, no auth)
Plain HTTP JSON on port 80, **zero authentication** (CVE-2013-4860; also
CVE-2018-11315 DNS-rebinding). Official "Radio Thermostat Wi-Fi API" PDF
mirrored by lowpowerlab (2015-10). Verified live on a CT50, fw 1.04.84,
API version 113 ([brannondorsey/radio-thermostat](https://github.com/brannondorsey/radio-thermostat), 2018-04).

Key endpoints:
- `GET  /tstat` — full state; `POST /tstat` with e.g.
  `{"tmode":1}` (0=off,1=heat,2=cool,3=auto), `{"t_heat":70}`,
  `{"t_cool":76}`, `{"a_heat":X}`/`{"a_cool":X}` (absolute program setpoints),
  `{"fmode":0|1|2}`, `{"hold":0|1}`, `{"override":0|1}`
- `GET /tstat/temp`, `/tstat/model`, `/tstat/version`, `/tstat/humidity` (CT80)
- `POST /tstat/led` `{"energy_led":0|1|2|4}`; CT80 display text:
  `POST /tstat/uma {"line":0,"message":"..."}`
- `GET/POST /sys/...` — name, network config, reboot
  (`POST /sys/command {"command":"reboot"}`), `/sys/system` lists all
  httpd handlers, `/cloud` exposes the cloud auth key
- Discovery: none documented — use DHCP reservation / ARP scan.

## Cloud steps required
None for control. **Caveat: initial Wi-Fi provisioning** of a fresh/reset
unit was originally done via the app or radiothermostat.com flow
(Hubitat user reports, 2022-12). The module can be re-joined locally:
USNAP Wi-Fi modules expose an AP/ provisioning mode and the network config
is also writable via `POST /sys/network` once on the LAN — but a fully
offline first-time join path is not cleanly documented; treat provisioning
as the one rough edge for rescued units.

## Existing implementations (confirmed)
- Home Assistant core `radiotherm` integration (local_polling), backed by
  the `radiotherm` Python lib (mhrivnak/radiotherm)
- openHAB `radiothermostat` binding (CT30/CT50/CT80/3M-50)
- Hubitat built-in Wi-Fi driver; old SmartThings/Vera plugins
- brannondorsey/radio-thermostat (curl cookbook, endpoint list above)

## Security note
No auth + no Host-header validation: anyone on the LAN (or a victim's
browser via DNS rebinding) can set the house temperature (demonstrated:
95°F via `/tstat t_heat`, CVE-2018-11315). Isolate on an IoT VLAN.

## Safety
HVAC actuator control — MEDIUM safety class.

## Sources
- Hubitat thread quoting RTCOA shutdown email (2022-12-21)
- energyhub.com news boilerplate ("independent subsidiary of Alarm.com", 2024-11)
- github.com/brannondorsey/radio-thermostat (2018-04-01) + CVE-2013-4860 / CVE-2018-11315
- home-assistant.io/integrations/radiotherm, openhab.org radiothermostat binding
- radiothermostat.com → 404, checked 2026-08-07
