# Snapmaker U1 Multi-Color 3D Printer

> **Status**: Complete (read/monitor path hardware-verified 2026-08-14; write/print and secure-MQTT documented from the vendor's open-sourced forks)
> **Protocol**: WiFi (Moonraker HTTP REST + JSON-RPC WebSocket on port 80)
> **Manufacturer**: Snapmaker (Shenzhen Snapmaker Technologies)
> **Manufacturer Status**: Active — cloud-independent local control; firmware is open source

## Overview

The Snapmaker U1 is a 2025/2026 CoreXY four-toolhead multi-color FDM printer.
Unlike Snapmaker's earlier SACP/HTTP-token machines, the U1 runs a
stock-shaped **Klipper + Moonraker + Fluidd** stack (Snapmaker's own GPL forks,
open-sourced 2026-03-30) on embedded Linux. Local control is therefore
ordinary Moonraker — and on stock firmware the REST/WebSocket API on port 80
is reachable **unauthenticated** on the LAN (all RFC-1918 ranges are in
Moonraker's `trusted_clients`). No cloud, no account, no pairing for local
monitoring or control.

Verified live 2026-08-14: a real U1 (Moonraker host "lava", firmware
1.5.1.2, Klipper ready) answered `/printer/info`, `/server/info`,
`/printer/objects/list` (showing all four toolheads `extruder`..`extruder3`)
and `/printer/objects/query` (bed 27 °C, a completed print on the bed) with
no API key.

## Hardware

| Property | Value |
|----------|-------|
| Type | CoreXY FDM, 4 independent toolheads (4-color) |
| Compute | Embedded Linux (Buildroot 2024.02), internal user `lava` |
| Firmware | Klipper (motion) + Moonraker (API) + Fluidd (UI), Snapmaker GPL forks |
| Discovery | mDNS `_snapmaker._tcp.local.` (TXT `ip`/`sn`/`device_name`/`link_mode`) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (for local control of a networked unit) |
| Method | Join Wi-Fi at the touchscreen; then Moonraker on port 80 |
| Passphrase protection | device_encrypted (Wi-Fi creds entered on-device) |
| Confidence | high (verified live; matches ha-snapmaker-u1) |

**Important:** the mDNS answer advertises port **1884** (the plain-MQTT LAN
broker), *not* the HTTP port. Ignore it and use **80** (upload falls back to
8080).

## Protocol Summary

Standard Moonraker: HTTP REST + JSON-RPC-2.0-over-WebSocket (`ws://<ip>/websocket`).

| Purpose | Endpoint |
|---------|----------|
| Identity / readiness | `GET /printer/info`, `GET /server/info` |
| Object list (4 toolheads) | `GET /printer/objects/list` |
| Telemetry | `GET /printer/objects/query?heater_bed&extruder&print_stats&display_status` |
| Live telemetry stream | `printer.objects.subscribe` over WebSocket |
| Files | `GET /server/files/list` |
| **Upload / print** | `POST /server/files/upload` (multipart), `POST /printer/print/{start,pause,resume,cancel}` — *advanced, moves a heated printer* |
| **G-code** | `POST /printer/gcode/script` — *advanced* |

A separate on-device **secure-MQTT** channel (plain 1884 / mTLS 8883, topics
`{SN}/request|response|notification`, touchscreen-approved cert pairing with
default access code `12345678`) mirrors the same JSON-RPC API — used by
Snapmaker Orca and the mobile app. It is not required for the local HTTP path.

## Tools Used

- `curl` against the live Moonraker API; mDNS browse

## References

- <https://github.com/Snapmaker/u1-moonraker>
- <https://github.com/Snapmaker/OrcaSlicer>
- <https://github.com/kbaker827/ha-snapmaker-u1>
- <https://moonraker.readthedocs.io/en/latest/web_api/>
