# Roku External Control Protocol

> **Status**: Complete local discovery and core control documented
> **Protocol**: WiFi (SSDP + HTTP REST on port 8060)
> **Manufacturer**: Roku / TCL
> **Manufacturer Status**: Active

## Overview

Roku TVs and players expose the External Control Protocol (ECP), a local HTTP
API with no authentication. Discovery starts with SSDP `ST: roku:ecp`; the
returned `LOCATION` identifies the host and port, and clients then fetch
`/query/device-info` for stable XML identity.

## Discovery

Use:

```bash
python scripts/roku_discover.py --timeout 5
```

Identity should use `serial-number` first, then `device-id`. The user-facing
name comes from `user-device-name`. AirPlay mDNS (`_airplay._tcp.local.`) can
also locate compatible TCL Roku TVs, but ECP identity should still be fetched
from `/query/device-info`.

## Local API

| Method | Path | Description |
|---|---|---|
| GET | `/query/device-info` | XML identity, model, serial, software version |
| GET | `/query/apps` | Installed apps and app IDs |
| GET | `/query/active-app` | Foreground app |
| GET | `/query/media-player` | Playback state and metadata |
| POST | `/keypress/<key>` | Remote key command |
| POST | `/launch/<app_id>` | Launch channel/app |
| POST | `/search/browse?keyword=...` | Search/browse UI |
| POST | `/input/<source>` | TV input switch |

Machine-readable spec: `device-specs/devices/roku-ecp.yaml`

