# SmartThings Hub v2

> **Status**: Local discovery and service map documented
> **Protocol**: WiFi (mDNS + SmartThings/Edge/Matter local services)
> **Manufacturer**: Samsung SmartThings
> **Manufacturer Status**: Active

## Overview

SmartThings Hub v2 advertises local SmartThings, Edge driver, and Matter
controller services. The primary stable identity is TXT `id` from
`_smartthings._tcp`. Every local endpoint it serves is gated behind a
cloud-issued Samsung bearer token, so this project identifies the hub and stops
there.

!!! tip "Running Home Assistant? Use LocalThings for your Samsung appliances"
    If this hub is on your network, the Samsung appliances on the same
    SmartThings account probably are too — and those can leave the cloud
    today. [LocalThings](https://github.com/mbillow/localthings) is a Home
    Assistant integration (HACS, domain `localthings`) that controls Samsung
    washers, dryers, refrigerators, air conditioners, ovens, dishwashers and
    more straight over your LAN, with no Samsung account. It needs Samsung's
    servers once, without logging in, for the first appliance, and never
    again.

    [Open LocalThings in HACS](https://my.home-assistant.io/redirect/hacs_repository/?owner=mbillow&repository=localthings&category=integration)
    · then
    [add an appliance](https://my.home-assistant.io/redirect/config_flow_start/?domain=localthings)
    by its IP address.

    LocalThings does not drive the hub itself, or the Zigbee and Z-Wave
    devices paired to it. Those stay on the hub, or move to a local
    coordinator (ZHA, Zigbee2MQTT, Z-Wave JS) — see
    [Keeping devices alive](../keeping-devices-alive.md).

## Discovery

Browse `_smartthings._tcp.local.` first. `_smartthings-hedge._tcp.local.` on
port 8766 is the Edge driver HTTPS service, and `_matter._tcp.local.`
advertises the hub's Matter controller node.

## Local Services

| Service | Port | TXT | Description |
|---|---:|---|---|
| `_smartthings._tcp.local.` | 8081 | `type=hubv2`, `id=...` | Primary hub service |
| `_smartthings-hedge._tcp.local.` | 8766 | `feat=ctrl` | Edge driver HTTPS (bearer token) |
| `_matter._tcp.local.` | 49722 | `T=6` | Matter controller (not a bridge) |

Observed hostname: `hubv2-0d052a80000000001.local`

Machine-readable spec: `device-specs/devices/smartthings-hub-v2.yaml`

## Home Assistant

| Integration | Path | Covers |
|---|---|---|
| [LocalThings](https://github.com/mbillow/localthings) (HACS, `localthings`) | **Local** — OCF over CoAP/DTLS to each appliance; HTTPS on TCP 8888 for 2018–2022 units | Samsung SmartThings-compatible appliances. Recommended. |
| Core [SmartThings](https://www.home-assistant.io/integrations/smartthings/) | Cloud — SmartThings API | Everything on the account, hub children included, while the cloud lasts |

LocalThings is built on the
[smartthings-local](https://github.com/QuiteYellow/SmartThings-Local) Python
library, the starting point for a client that is not Home Assistant.

