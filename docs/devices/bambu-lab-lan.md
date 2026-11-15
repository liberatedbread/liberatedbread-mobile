# Bambu Lab 3D Printer (LAN mode)

> **Status**: Spec Available (unverified) — active; cloud-first vendor, LAN is the rescue
> **Protocol**: WiFi
> **Manufacturer**: Bambu Lab
> **Manufacturer Status**: Active

## Overview

Bambu Lab printers (X1/P1/A1) can be driven over the LAN with no cloud, but the 2024–2025 firmware 'authorization' change gated LAN/third-party access — so the community-documented LAN mode is the rescue path. All local transports use the printer's LAN Access Code.

## Protocol Summary

MQTT over TLS 8883 (publish device/{serial}/request, subscribe device/{serial}/report; pause/resume/stop/pushall), FTPS 990 for files, and a camera on RTSPS 322 (X1/H2) or raw TCP+TLS 6000 (A1/P1). User bblp + LAN Access Code.

See `device-specs/devices/bambu-lab-lan.yaml` for the full machine-readable spec.

## References

- <https://github.com/Doridian/OpenBambuAPI/blob/main/mqtt.md>
- <https://github.com/Doridian/OpenBambuAPI/blob/main/video.md>
- <https://github.com/Doridian/OpenBambuAPI/blob/main/ftp.md>
