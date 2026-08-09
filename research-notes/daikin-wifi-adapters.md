# Daikin Wi-Fi Adapters for Mini-Splits (BRP069 / BRP072 families) — Research Notes

## What it is
Daikin's plug-in Wi-Fi controller boards for residential mini-split /
multi-split / ducted units. Adapter generations matter a lot for local
control (Daikin is **active**; local API availability is model/firmware
dependent):

- **BRP069A41/42/43/45** (EU, "Daikin Online Controller" app),
  **BRP069B41** (US), **BRP072A42/C42** (AU, "Daikin Mobile Controller"
  app) — classic local HTTP API, **no auth**.
- **BRP069C4x** ("Daikin Residential Controller" era) — same-style local
  API but requires an **API key + password** (retrieved from the adapter /
  app per HA docs).
- **Newest Onecta-generation adapters** (2023+) — local API **removed**;
  control is Onecta cloud only (HA community reports, 2024-06+).

## Local protocol (community-documented, HA core integration)
- Plain HTTP GET on port 80, query-string RPC, CSV-ish `key=value` bodies:
  - `GET /common/basic_info` — name, MAC, firmware
  - `GET /aircon/get_model_info`, `/aircon/get_control_info`,
    `/aircon/get_sensor_info` (inside/outside temp, humidity)
  - `GET /aircon/set_control_info?pow=1&mode=3&stemp=22&shum=0&f_rate=A&f_dir=0`
    — pow 0/1, mode 0/1/7=auto 2=dry 3=cool 4=heat 6=fan, f_rate fan
    speed A/auto/3/4/5/B…, f_dir swing
- Discovery: UDP broadcast probe (ports 30000/30050) used by the HA
  integration; or DHCP reservation.
- Home Assistant core `daikin` integration: `iot_class: local_polling`,
  supports the auth variants for BRP069C4x ([HA docs, accessed
  2026-08-07](https://www.home-assistant.io/integrations/daikin/)).

## Cloud steps required
None for the classic/BRP069C4x adapters once on Wi-Fi (Wi-Fi provisioning
is via the adapter's AP mode + app, which works locally). The Onecta-app
generation is the dud — cloud only.

## Existing implementations
- HA core `daikin` integration (pydaikin library)
- ESPHome `daikin_brc52b6x` and faikin-style replacement boards as
  hardware alternatives for units with dead/removed local APIs

## Safety
HVAC actuator control — MEDIUM. Classic adapters have **no auth**: any LAN
client can drive the unit; VLAN isolation recommended.

## Sources
- home-assistant.io/integrations/daikin (accessed 2026-08-07)
- HA community "Is Daikin AC integration local-control possible … 2024 and
  onward" (2024-06: local API removed in newer products, Onecta cloud only)
- HA community "Daikin Integration problem" (2025-03: API key location
  discussion for BRP069C4x)
