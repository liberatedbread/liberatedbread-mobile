# Enphase Envoy

> **Status**: Local discovery and production endpoints documented
> **Protocol**: WiFi (mDNS + HTTP REST on port 80)
> **Manufacturer**: Enphase Energy
> **Manufacturer Status**: Active

## Overview

Enphase Envoy gateways provide local solar production telemetry over HTTP.
Newer firmware may require token authentication for some endpoints, but mDNS
still provides a stable serial number for discovery and identity.

## Discovery

Browse `_enphase-envoy._tcp.local.` on port 80. TXT `serialnum` is the stable
identity; TXT `protovers` reports the protocol/firmware version.

Use:

```bash
python scripts/enphase_discover.py --timeout 5
```

The discovery script resolves the mDNS service and probes `/production.json`
to confirm the local REST endpoint.

## Local API

| Method | Path | Description |
|---|---|---|
| GET | `/production.json` | Live production/consumption summary |
| GET | `/api/v1/production` | Production summary |
| GET | `/api/v1/production/inverters` | Per-inverter telemetry |
| GET | `/info` | Gateway information |

Machine-readable spec: `device-specs/devices/enphase-envoy.yaml`

