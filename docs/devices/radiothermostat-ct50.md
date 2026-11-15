# Radio Thermostat CT30/CT50/CT80

> **Status**: Shutdown — vendor cloud discontinued 2023-05-15
> **Protocol**: WiFi
> **Manufacturer**: Radio Thermostat Company of America
> **Manufacturer Status**: Shutdown

## Overview

Wi-Fi thermostats (and the 3M Filtrete 3M50 rebrand) with a documented local REST API. The vendor cloud is dead, so the local API is the only thing keeping these smart — a textbook rescue.

## Protocol Summary

Plain HTTP JSON on port 80, no auth: `GET/POST /tstat` (tmode/fmode/temp/t_heat/t_cool), `/tstat/program/...`, and `POST /cloud {"enabled":0}` to stop the dead-cloud callbacks. Marvell WM-DISCOVER SSDP.

See `device-specs/devices/radiothermostat-ct50.yaml` for the full machine-readable spec.

## References

- <https://www.openhab.org/addons/bindings/radiothermostat/>
- <https://github.com/mhrivnak/radiotherm>
