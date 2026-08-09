# Venstar ColorTouch / Explorer Wi-Fi Thermostats — Research Notes

## What it is
Venstar (Chatsworth, CA) residential/commercial Wi-Fi thermostats. Local API
models: T7850, T7900, T8850, T8900 (built-in Wi-Fi); T5800/T5900/T6800/T6900
with the ACC0454 Skyport Wi-Fi Key; also rebadges: First Alert THERM-500
(Onelink) and some Carrier/Bryant units. Company **active** as of 2026-08
(venstar.com reachable; Home Assistant core integration maintained).

## Why it's valuable
One of the very few Wi-Fi thermostats with a **vendor-documented local
HTTP(S) API** that works with the cloud (Skyport) fully disabled. No account,
no provisioning cloud step: Wi-Fi is configured on-device and the local API
is toggled at Menu → Wi-Fi → Local API.

## Local protocol (vendor-documented)
- Enable: `Menu → Wi-Fi → Local API → ON`; choose HTTP or HTTPS, optional
  Basic auth. Enable "Local API" before anything else.
- Discovery: **SDDP** (Control4 Simple Device Discovery) — unit sends
  `NOTIFY ALIVE SDDP/1.0` from port 1902 with
  `Type: "venstar:control4_thermostat_proxy:colortouch"`,
  `Manufacturer: "Venstar"`, `Model: "ColorTouch"` (observed 2022-04,
  [karlquinsland teardown](https://karlquinsland.com/venstar-t7850-teardown-review/)).
- `GET /` → `{"api_ver":9,"type":"residential","model":"COLORTOUCH","firmware":"6.91"}`
- Main endpoints (all JSON):
  - `GET /query/info` — mode, state, temps, humidity, setpoints
  - `GET /query/sensors` — onboard + remote sensor temps
  - `GET /query/runtimes` — daily runtimes (last 7 days)
  - `GET /query/alerts`, `GET /query/programs` (program schedule read)
  - `POST /control` — `{"mode":0..3, "fan":0..1, "heattemp":X, "cooltemp":Y}`
  - `POST /settings` — e.g. `{"tempunits":0|1}`, away mode, schedule on/off,
    humidity setpoints
- HTTPS: self-signed cert chained to a Venstar "Skyport Root CA"
  (CN=`CT1A_<serial>`), TLS 1.2; no client cert needed for the local API.
- Observed open ports: 443 (HTTPS) and 53 (odd; likely captive-DNS stub).

## API limitations (from the 2022 teardown)
- No documented control of screen brightness, clock, vacation mode, or
  setpoint limits — screen-only.
- No NTP (clock set manually); firmware auto-updates cannot be disabled and
  the unit reboots to apply them; it phones `ctupdate.skyport.io` even with
  Skyport cloud off — sinkhole or firewall if you want it fully quiet.

## Cloud requirement
**None.** Setup, Wi-Fi config, and the entire local API are usable without a
Skyport account. Skyport app/cloud is optional remote access only.

## Existing implementations (confirmed)
- Home Assistant core `venstar` integration (`iot_class: local_polling`) —
  [docs](https://www.home-assistant.io/integrations/venstar/)
- toggledbits/VenstarColorTouch (Vera) and VenstarColorTouch-Hubitat drivers
- Official Venstar "Local API" PDF (linked from HA docs / driver repos)

## Safety
HVAC control: default MEDIUM safety class applies (heat/cool actuator).
Auth is optional — on an untrusted LAN enable HTTPS + Basic auth, since
unauthenticated HTTP lets any LAN client drive the furnace/AC.

## Sources
- karlquinsland.com teardown (2022-04-23): firmware, TLS, SDDP, API gaps
- home-assistant.io/integrations/venstar (accessed 2026-08-07)
- github.com/toggledbits/VenstarColorTouch-Hubitat (setup steps)
- driverstore.rticontrol.com Venstar ColorTouch driver (model matrix)
