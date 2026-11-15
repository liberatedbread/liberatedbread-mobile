# Yeelight Wi-Fi Lights (LAN Control)

> **Status**: Spec Available (unverified) — active; vendor-documented protocol
> **Protocol**: WiFi
> **Manufacturer**: Qingdao Yeelink Information Technology (Xiaomi ecosystem)
> **Manufacturer Status**: Active

## Overview

Yeelight's Wi-Fi bulbs/strips/ceiling lights, controllable locally over a vendor-documented protocol — but the per-device "LAN Control" toggle must be enabled once in the app before the port answers. See also the [Yeelight Cube Lamp](yeelight-cube-lamp.md), one product on this protocol.

## Protocol Summary

JSON over TCP 55443 (CRLF-terminated), no auth: `set_power`, `set_bright`, `set_rgb`, `set_ct_abx`, `get_prop`. Simplified SSDP on 239.255.255.250:1982 (not 1900), ST `wifi_bulb`.

See `device-specs/devices/yeelight-wifi.yaml` for the full machine-readable spec.

## References

- <https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf>
- <https://gitlab.com/stavros/python-yeelight>
- <https://www.home-assistant.io/integrations/yeelight/>
