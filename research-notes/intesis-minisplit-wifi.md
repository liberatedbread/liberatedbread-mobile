# Intesis Wi-Fi Mini-Split Modules (IntesisHome IS-IR-WIFI-1, Airconwithme, IntesisBox WMP) — Research Notes

## What it is
Intesis (now HMS Networks, acquired 2016) sells brand-specific Wi-Fi
gateways that plug into the internal bus of mini-split / VRF air
conditioners: Fujitsu, Mitsubishi Electric/Heavy, Daikin, Toshiba, LG,
Panasonic, Samsung, Hitachi, plus a generic IR module. Generations:

1. **IntesisBox WMP gateways** (e.g. INWMPFGX001I000 family, wired/Wi-Fi
   variants, "…-WMP-1") — pro line, **vendor-published local API**.
2. **IntesisHome IS-IR-WIFI-1 / INWFIxxx001I000 consumer Wi-Fi modules**
   (2014–2020s), also sold as **Airconwithme** — had an undocumented local
   HTTP API; **HMS removed it in a 2025 firmware update** citing EU RED
   cybersecurity compliance.
3. Current "AC Cloud" generation — cloud-first.

Company is **active** (hms-networks.com; airconwithme.com redirects there,
checked 2026-08-07).

## Local protocol A — IntesisBox WMP (vendor-documented, confirmed)
- Plain TCP **port 3310**, ASCII line protocol ("WMP"), published by
  HMS/Intesis as the WMP Protocol Specification (PDF on hms-networks.com).
- Discovery: UDP broadcast on port 3310 (`DISCOVER` frames).
- Session: `LOGIN` (user `admin`/`operator`, default password `admin` /
  device code), then `GET,SET,ID` / `SET,ID,FUNCTION,VALUE` /
  `CHN,ID,FUNCTION,VALUE` style frames; async `CHN` pushes on state change.
- Functions include ONOFF, MODE (AUTO/HEAT/DRY/FAN/COOL), SETPTEMP,
  AMBTEMP, FANSP, VANEUD/VANELR, ERRSTATUS/ERRCODE.
- Clients: openHAB intesis binding, Domoticz "IntesisBox WMP-1" hardware
  type, jnimmo/hass-intesishome (local mode), pyintesishome local class.
- **No cloud needed at any point** — config via local web UI or Intesis
  MAPS tool; these are the recommended units to buy for local control.

## Local protocol B — IntesisHome IS-IR-WIFI-1 (frozen firmware, caveat)
- Pre-2025 firmware: local HTTP API on port 80 (JSON posts with basic
  auth; default `admin`/`admin`-style creds), discovered/used by the
  hass-intesishome local fork. Worked for years.
- **2025 firmware update removed the local web server entirely** — port 80
  stays open but serves nothing; support confirmed to a user (2025-08) that
  local access was dropped for EU RED 2014/53/EU compliance and everything
  is forced through Intesis AC Cloud
  ([HA thread](https://community.home-assistant.io/t/intesishome-stop-working-after-update/873343)).
- Rescue options: keep/block firmware updates (units already on old firmware
  retain local API; block WAN to prevent the update), or replace with a
  WMP gateway or ESPHome-based controller.

## Cloud steps required
- WMP: none.
- IntesisHome consumer modules: initial Wi-Fi pairing was done in the
  IntesisHome/Airconwithme app (cloud account). Local API afterwards needed
  no cloud — until HMS killed it server-push-side via firmware.

## Existing implementations
- jnimmo/hass-intesishome (fork of HA intesishome with local mode; notes:
  "IntesisBox devices use the WMP protocol over a local TCP connection.
  Only an IP address or hostname is required — no cloud account needed.")
- openHAB intesis/intesishome bindings; Domoticz WMP-1 device
- domoticz/domoticz#4193 documents the WMP port-3310 design (2020-05)

## Safety
HVAC actuator control — MEDIUM. WMP default credentials are public;
change the password and/or isolate VLAN.

## Sources
- github.com/jnimmo/hass-intesishome (README; accessed 2026-08-07)
- HA forum "Intesishome stop working after update" (2025-04 → 2025-08)
- github.com/domoticz/domoticz/issues/4193 (2020-05-31)
- forum.domoticz.com WMP thread (2019-06)
- hms-networks.com/software-and-tools/intesis-ac-cloud-control (2024-09)
