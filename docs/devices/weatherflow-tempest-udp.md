# WeatherFlow Tempest

> **Status**: Spec Available (unverified) — active; vendor-published local API
> **Protocol**: WiFi
> **Manufacturer**: WeatherFlow-Tempest, Inc.
> **Manufacturer Status**: Active

## Overview

A home weather station whose hub broadcasts JSON observations on the LAN.
WeatherFlow publishes the local UDP API itself. After separate app/Wi-Fi
provisioning, current observations need no cloud request, token or pairing.
UDP is unauthenticated, so validate sender metadata, message shape and lengths
on a trusted LAN.

## Protocol Summary

Listen passively for JSON over UDP broadcast on port 50222. Message types are
`obs_st`, legacy `obs_air` / `obs_sky`, `rapid_wind`, `evt_precip`,
`evt_strike`, `device_status` and `hub_status`. Use `serial_number` and `type`
to select a layout; unknown serials and types remain unknown.

### Tempest `obs_st`

The first `obs` element must contain 18 values:

| Index | Field | Units / rule |
|---:|---|---|
| 0 | Epoch | Seconds |
| 1–3 | Wind lull / average / gust | m/s |
| 4 | Wind direction | Degrees |
| 5 | Wind sample interval | Seconds; 3/6/60/300 maps to power-save modes 0/1/2/3 |
| 6 | Station pressure | mbar, not sea-level-adjusted pressure |
| 7 | Air temperature | °C |
| 8 | Relative humidity | % |
| 9 | Illuminance | lux |
| 10 | UV | Index |
| 11 | Solar radiation | W/m² |
| 12 | Rain over the **previous minute** | mm; not a daily or report-interval total |
| 13 | Precipitation type | 0 none, 1 rain, 2 hail, 3 rain+hail (experimental) |
| 14 | Lightning average distance | km; nullable |
| 15 | Lightning strike count | Count |
| 16 | Battery | Volts, not percent |
| 17 | Report interval | Minutes |

Reject a short observation rather than indexing past its end. Null is
unavailable, not zero. Multiplying index 12 by 60 gives a rain rate in mm/h;
it does not supply a trustworthy daily total. Rapid wind is instantaneous and
must not overwrite the report-interval average at index 2.

### Legacy layouts and events

AIR and SKY have different layouts; never apply `obs_st` offsets to them.
The YAML declares all eight AIR and 14 SKY fields. In particular, SKY index 11
is local-day rain accumulation, unlike Tempest index 12.

`rapid_wind.ob` is `[epoch, speed_mps, direction_degrees]`. `evt_strike.evt`
is `[epoch, distance_km, energy]`: distance 63 means out of range, and energy
is an opaque integer with affected firmware's bit 24 cleared, not a value with
an invented physical unit. Ignore events older than the latest accepted one.

### Status and validation

`device_status` carries voltage, RSSI/hub RSSI, sensor-status bits, firmware
and its own timestamp/uptime. Status zero means sensors OK. The YAML maps the
lightning, pressure, temperature, humidity, wind, precipitation, light and
power-booster bits, plus hub reset/radio states. These diagnostics are not
weather observations or battery percentages.

Local UDP supplies current observations and events, not cloud history,
forecast, calibration or an on-demand history endpoint. Initial station
claiming and Wi-Fi setup still use the vendor app/account; no account-free
provisioning path is claimed.

The complete field tables and parser requirements are in
`device-specs/devices/weatherflow-tempest-udp.yaml`. The 2026-11-01 review
checked vendor v171 and `pyweatherflowudp` at `c89fa2ae`; its upstream offline
tests passed, but no physical station was accessed.

## References

- [WeatherFlow Tempest UDP API v171](https://weatherflow.github.io/Tempest/api/udp/v171/)
- [briis/pyweatherflowudp](https://github.com/briis/pyweatherflowudp)
