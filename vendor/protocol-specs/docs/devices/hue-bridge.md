# Philips Hue Bridge

> **Status**: Complete local discovery and API summary documented
> **Protocol**: WiFi (mDNS/SSDP + HTTP REST on port 80)
> **Manufacturer**: Signify / Philips Hue
> **Manufacturer Status**: Active

## Overview

Hue Bridge v2 exposes a local REST API on port 80. `GET /api/config` is
readable without authentication. Light, sensor, group, and scene control uses a
whitelist username created with the physical link-button pairing flow.

## Discovery

Primary discovery is mDNS `_hue._tcp.local.` on port 80. Stable identity is the
TXT `bridgeid`, with TXT `mac` as a secondary key. UPnP/SSDP is a fallback via
`upnp:rootdevice` or `urn:schemas-upnp-org:device:Basic:1` and
`/description.xml`.

Use:

```bash
python scripts/hue_discover.py --timeout 5
```

## Local API

| Method | Path | Description |
|---|---|---|
| GET | `/api/config` | Bridge metadata, no auth |
| POST | `/api` | Press-link pairing creates username |
| GET | `/api/<username>/lights` | Enumerate lights |
| PUT | `/api/<username>/lights/<id>/state` | Set light state |
| GET | `/api/<username>/sensors` | Enumerate sensors |
| GET | `/api/<username>/groups` | Enumerate rooms/zones |
| GET | `/api/<username>/scenes` | Enumerate scenes |

Machine-readable spec: `device-specs/devices/hue-bridge.yaml`

