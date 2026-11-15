# Gree Smart Air Conditioner (LAN)

> **Status**: Spec Available (unverified) — active; firmware moved ECB→GCM
> **Protocol**: WiFi
> **Manufacturer**: Gree Electric Appliances (many OEM rebrands: Cooper & Hunter, etc.)
> **Manufacturer Status**: Active

## Overview

Gree Wi-Fi ACs and the many OEM rebrands, controllable entirely on the LAN with no cloud.

## Protocol Summary

UDP/JSON on port 7000; the `pack` field is AES-128-ECB (newer firmware AES-GCM), Base64. Broadcast `{"t":"scan"}`, bind for a per-device key, then `status`/`cmd` with parameter names (Pow, Mod, SetTem, WdSpd).

See `device-specs/devices/gree-ac-lan.yaml` for the full machine-readable spec.

## References

- <https://github.com/tomikaa87/gree-remote>
- <https://github.com/cmroche/greeclimate>
