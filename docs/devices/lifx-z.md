# LIFX Z

> **Status**: Local discovery and UDP LAN protocol summary documented
> **Protocol**: WiFi (mDNS + binary UDP on port 56700)
> **Manufacturer**: LIFX
> **Manufacturer Status**: Active

## Overview

LIFX Z strips use the LIFX binary LAN protocol over UDP port 56700 with no
authentication. The observed devices advertise HomeKit HAP records with
`md=LIFX Z`; after mDNS resolution, clients should send LIFX `GetService`
message type `2` to port 56700.

## Discovery

Use:

```bash
python scripts/lifx_discover.py --timeout 5
```

The script browses `_hap._tcp.local.`, filters TXT `md=LIFX Z`, resolves the
host address, and sends a UDP GetService probe.

## LAN Protocol

| Message | Type | Description |
|---|---:|---|
| GetService | 2 | Discover LIFX service type and port |
| StateService | 3 | Service discovery response |
| Get | 101 | Request light state |
| SetColor | 102 | Set HSBK color |
| State | 107 | Light state response |
| SetPower | 117 | Set power |

## Setup (adopting a reset strip)

An unprovisioned or factory-reset strip hosts an open AP named with the
`LIFX` prefix and sits at `172.16.0.1` on it. The credential exchange is the
deprecated access-point message family the original published LAN protocol
documented — `GetAccessPoints` (0x130), `SetAccessPoint` (0x131, plaintext
passphrase, interface = STATION), `StateAccessPoint` (0x132) — over the same
UDP port 56700. Transcribed from legacy public reverse-engineering
documentation (magicmonkey/lifxjs), unverified against hardware here, and
LCM3/Matter-era firmware onboards over BLE instead. Full layouts, timing and
troubleshooting: `device.setup` in the machine-readable spec.

Machine-readable spec: `device-specs/devices/lifx-z.yaml`

