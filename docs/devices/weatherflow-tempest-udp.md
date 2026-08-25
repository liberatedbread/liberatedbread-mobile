# WeatherFlow Tempest

> **Status**: Spec Available (unverified) — active; vendor-published local API
> **Protocol**: WiFi
> **Manufacturer**: WeatherFlow-Tempest, Inc.
> **Manufacturer Status**: Active

## Overview

A home weather station whose hub broadcasts JSON observations on the LAN — WeatherFlow publishes the local UDP API itself. No cloud, no auth.

## Protocol Summary

JSON over UDP broadcast, port 50222. Message types `obs_st` (the combined observation), `rapid_wind`, `evt_precip`, `evt_strike`, `hub_status`. Passive receive only.

See `device-specs/devices/weatherflow-tempest-udp.yaml` for the full machine-readable spec.

## References

- <https://weatherflow.github.io/Tempest/api/udp/v171/>
