# Dyson Air Purifier

> **Status**: Local discovery and MQTT topic structure documented
> **Protocol**: WiFi (mDNS + local MQTT broker on port 1883)
> **Manufacturer**: Dyson
> **Manufacturer Status**: Active

## Overview

Dyson purifier models advertise a local MQTT broker. The device is the broker,
and topics are scoped by serial number. Credentials are derived from the device
serial and WiFi password during/after pairing.

## Discovery

Browse `_dyson_mqtt._tcp.local.` on port 1883. The hostname contains the serial
number, such as `F3H-US-PFA5664A.local`.

Use:

```bash
python scripts/dyson_discover.py --timeout 5
```

## MQTT Topics

| Topic | Direction | Description |
|---|---|---|
| `<serial>/status/current` | Subscribe | Current purifier state |
| `<serial>/status/connection` | Subscribe | Connection/availability state |
| `<serial>/command` | Publish | Power, mode, fan, oscillation, humidifier commands |

Machine-readable spec: `device-specs/devices/dyson-air-purifier.yaml`

