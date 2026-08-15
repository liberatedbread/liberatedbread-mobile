# PurpleAir Air Quality Sensor

> **Status**: Complete (local JSON API hardware-verified 2026-08-14)
> **Protocol**: WiFi (unauthenticated HTTP JSON on port 80)
> **Manufacturer**: PurpleAir, Inc.
> **Manufacturer Status**: Active — fully local by design; cloud upload is optional

## Overview

PurpleAir particulate sensors run an ESP (Espressif) SoC that serves a small
**unauthenticated JSON API on port 80** — every measurement is readable
locally with no PurpleAir account, no ThingSpeak key, and no internet. The
device pushes to the cloud, but the local `/json` read path is wholly
independent of it, making PurpleAir one of the cleanest local-first sensors.

Verified live 2026-08-14 (firmware 7.02, hardware 2.0, BME280 + one PMSX003
laser): `GET /json` and `/json?live=false` returned the 120-second average,
`/json?live=true` returned the instantaneous reading, unauthenticated.

## Hardware

| Property | Value |
|----------|-------|
| Compute | Espressif ESP SoC |
| Sensors | 1–2 × PMSX003 laser particle counter, BME280 temp/humidity/pressure |
| Channels | single-laser (channel A only) or dual-laser PA-II (adds `_b` fields) |
| Identity | `SensorId` (= MAC) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (to read a networked sensor) |
| Method | `GET http://<ip>/json` |
| Passphrase protection | device_encrypted (Wi-Fi via the `PurpleAir-XXXX` SoftAP + `/config`) |
| Confidence | high (verified live) |

## Protocol Summary

| Endpoint | Meaning |
|----------|---------|
| `GET /json` / `?live=false` | 120-second average (what the web UI shows) |
| `GET /json?live=true` | instantaneous single sample |

Key fields: `pm2_5_atm` (outdoor calibration, µg/m³ — use for outdoor;
`pm2_5_cf_1` for indoor), `p_0_3_um`…`p_10_0_um` (particle counts per
deciliter), `pm2.5_aqi` + `p25aqic` (on-device US-EPA AQI + color),
`current_temp_f` (reads ~8 °F high — subtract for ambient), `current_humidity`
(~4 %RH low), `pressure` (hPa). Dual-laser units repeat PM/count fields with a
`_b` suffix for a data-quality cross-check.

Cloud dependency: none for local reads. The `status_*` flags report cloud/NTP
reachability but a fully offline device still serves `/json`.

## Tools Used

- `curl` against the live `/json` API

## References

- <https://community.purpleair.com/t/local-json-documentation/6917>
- <https://api.purpleair.com/>
