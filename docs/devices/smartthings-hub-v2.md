# SmartThings Hub v2

> **Status**: Local discovery and service map documented
> **Protocol**: WiFi (mDNS + SmartThings/Edge/Matter local services)
> **Manufacturer**: Samsung SmartThings
> **Manufacturer Status**: Active

## Overview

SmartThings Hub v2 advertises local SmartThings, Edge driver, and Matter bridge
services. The primary stable identity is TXT `id` from `_smartthings._tcp`.

## Discovery

Browse `_smartthings._tcp.local.` first. `_smartthings-hedge._tcp.local.` on
port 8766 exposes Edge driver WebSocket features, and `_matter._tcp.local.`
advertises the Matter bridge endpoint.

## Local Services

| Service | Port | TXT | Description |
|---|---:|---|---|
| `_smartthings._tcp.local.` | 8081 | `type=hubv2`, `id=...` | Primary hub service |
| `_smartthings-hedge._tcp.local.` | 8766 | `feat=ctrl` | Edge driver WebSocket |
| `_matter._tcp.local.` | 49722 | `T=6` | Matter bridge |

Observed hostname: `hubv2-0d052a8a662bc0001.local`

Machine-readable spec: `device-specs/devices/smartthings-hub-v2.yaml`

