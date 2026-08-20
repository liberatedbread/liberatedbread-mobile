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
| GET | `/api/v1/production` | Production summary (flat object: `wattsNow`, `wattHoursToday`, `wattHoursSevenDays`, `wattHoursLifetime`) |
| GET | `/api/v1/production/inverters` | Per-inverter telemetry |
| GET | `/info` | Gateway information |

The spec's sensor entities (Solar Production, Lifetime Energy, Today's
Energy) bind `GET /api/v1/production` as their `state_command` with flat
dotted-path state mappings (`wattsNow`, `wattHoursLifetime`,
`wattHoursToday`), so a generic HTTP client can poll them directly.
`/production.json` is richer but returns a per-type ARRAY (`production[i].wNow`
/ `whLifetime`), which a flat path cannot name — consumers that can select
array entries should prefer it, and metered units report lifetime energy only
there.

Machine-readable spec: `device-specs/devices/enphase-envoy.yaml`

