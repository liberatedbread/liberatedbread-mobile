# Rachio Controller

> **Status**: Local discovery documented
> **Protocol**: WiFi (mDNS HomeKit HAP)
> **Manufacturer**: Rachio
> **Manufacturer Status**: Active

## Overview

The observed Rachio controller advertises HomeKit HAP via mDNS and has port 80
open. This entry documents local discovery and identity; a full local control
protocol still needs capture or HAP implementation work.

## Discovery

Browse `_hap._tcp.local.` and match Rachio model TXT values such as
`md=Rachio-B68A9A`. Use TXT `id` as the stable identity.

Observed identity:

| Field | Value |
|---|---|
| Hostname | `WICED-hap-B68A9A.local` |
| HAP ID | `0A:01:0A:36:39:1E` |
| Model TXT | `Rachio-B68A9A` |

Machine-readable spec: `device-specs/devices/rachio-controller.yaml`

