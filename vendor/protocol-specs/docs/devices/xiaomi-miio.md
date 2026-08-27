# Xiaomi miIO Protocol

> **Status**: Spec Available (unverified) — active; transport for many device classes
> **Protocol**: WiFi
> **Manufacturer**: Xiaomi (and ecosystem OEMs — Roborock, Dreame, Viomi, etc.)
> **Manufacturer Status**: Active

## Overview

The local UDP transport spoken by a huge range of Xiaomi/Mijia ecosystem devices (vacuums, purifiers, plugs, lights). Documenting the transport lets every miIO device be reached locally once its token is known.

## Protocol Summary

Encrypted binary over UDP 54321: 32-byte header, a Hello handshake that returns the device token, AES-128-CBC payloads (Key=MD5(Token)), JSON-RPC commands. The per-device token is usually extracted once from the cloud.

See `device-specs/devices/xiaomi-miio.yaml` for the full machine-readable spec.

## References

- <https://github.com/OpenMiHome/mihome-binary-protocol/blob/master/doc/PROTOCOL.md>
- <https://github.com/rytilahti/python-miio>
