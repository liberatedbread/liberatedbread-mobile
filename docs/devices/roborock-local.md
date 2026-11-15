# Roborock Robot Vacuum (local)

> **Status**: Spec Available (unverified) — active; local key is cloud-fetched once
> **Protocol**: WiFi
> **Manufacturer**: Roborock
> **Manufacturer Status**: Active

## Overview

Roborock vacuums can be driven locally over TCP, removing the cloud from the command path — but the per-device local key and map data are fetched via a one-time Roborock cloud login.

## Protocol Summary

TCP 58867: length-prefixed header + AES-128-ECB JSON + CRC32; key = MD5(timestamp + local_key + SALT). `get_status`, `app_start`, `app_charge`. A01 devices (Dyad, Zeo) are cloud-only.

See `device-specs/devices/roborock-local.yaml` for the full machine-readable spec.

## References

- <https://www.home-assistant.io/integrations/roborock/>
- <https://github.com/Python-roborock/python-roborock>
- <https://github.com/KonradIT/roborock-remote>
