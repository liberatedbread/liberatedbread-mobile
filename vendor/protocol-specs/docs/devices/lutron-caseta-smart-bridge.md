# Lutron Caseta Smart Bridge 2

> **Status**: Local discovery and service map documented
> **Protocol**: WiFi (mDNS + LEAP TLS JSON/WebSocket)
> **Manufacturer**: Lutron
> **Manufacturer Status**: Active

## Overview

Lutron Caseta Smart Bridge 2 exposes multiple local services. LEAP on port
8081 is the modern local control protocol. LAP on port 8083 is deprecated.
`_lutron._tcp.local.` exposes stable bridge metadata such as `MACADDR`,
`CODEVER`, `SYSTYPE`, and `DEVCLASS`.

## Discovery

Use:

```bash
python scripts/lutron_discover.py --timeout 5
```

Stable identity should prefer TXT `MACADDR` from `_lutron._tcp.local.`, with
hostname as a fallback.

## Local Services

| Service | Port | Description |
|---|---:|---|
| `_leap._tcp.local.` | 8081 | Modern TLS JSON/WebSocket control |
| `_lap._tcp.local.` | 8083 | Deprecated local protocol (also hosts cert pairing) |
| `_lutron._tcp.local.` | 22 | Status/identity TXT records |
| `_hap._tcp.local.` | 4548 | HomeKit accessory service |

LEAP frames are one JSON object: `{"CommuniqueType": ..., "Header": {"Url":
...}, "Body": ...}`. Pairing runs on port 8083 while the rear button is held:
`Execute /pair` with `CommandType=CSR` and the client's PEM CSR returns the
signed client certificate plus the bridge CA in `Body.SigningResult`.
Zone control is a `CreateRequest` to `/zone/{id}/commandprocessor` —
dimmers `GoToDimmedLevel` (Level 0–100), switches `GoToSwitchedLevel`
(On/Off), shades `GoToShadeLevel`/`GoToTilt`. (Verified against vendor app
com.lutron.mmw 26.7.0.5, 2026-08-20.)

Machine-readable spec: `device-specs/devices/lutron-caseta-smart-bridge.yaml`

Home Assistant: the core [Lutron Caséta integration](https://www.home-assistant.io/integrations/lutron_caseta/) uses the Smart Bridge LEAP protocol documented here.

