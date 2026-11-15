# Fronius Solar Inverter (Solar API V1)

> **Status**: Spec Available (unverified) — active; vendor-documented
> **Protocol**: WiFi
> **Manufacturer**: Fronius International
> **Manufacturer Status**: Active

## Overview

Fronius solar inverters/dataloggers expose a local JSON REST API for telemetry — read-only and, notably, unauthenticated.

## Protocol Summary

HTTP `/solar_api/v1/` (GetInverterRealtimeData, GetPowerFlowRealtimeData, GetMeterRealtimeData). `GET /solar_api/GetAPIVersion.cgi` negotiates the base path. GEN24 has an enable switch and may use HTTPS.

See `device-specs/devices/fronius-solar-api.yaml` for the full machine-readable spec.

## References

- <https://www.fronius.com/en/solar-energy/installers-partners/technical-data/all-products/system-monitoring/open-interfaces/fronius-solar-api-json->
- <https://github.com/mwittig/node-fronius-solar>
