# eGauge EG3000 / EG4xxx — Research Notes

## What it is
eGauge Systems (Boulder, CO; ACTIVE 2026-08) makes CT-based revenue-grade
energy meters: EG3000 series and the current EG4xxx line (e.g. EG4115 "Core",
15 channels; EG4015 "Pro"). DIN-rail/panel devices with Ethernet, used
heavily for solar monitoring.

## Local-first by design
eGauge's long-standing pitch: all data lives on the meter, no subscription, no
mandatory cloud. The web UI and all APIs below are served by the device on the
LAN; the optional eGauge.net service is only a reverse-proxy convenience for
remote access.

## Local APIs — vendor-documented
Docs: kb.egauge.net ("eGauge Meter Communication") and webapi.egauge.net.

- **JSON WebAPI** (modern): `GET /api/registers?rate` → instantaneous per-
  register power (W); `/api/register?...&time=...` → historical accumulated
  values; `/api/auth` for session tokens (HTTP Digest against local user
  accounts such as `owner`). Full read + config access.
- **Legacy XML API** (zero-auth if meter is in default "allow all" mode):
  `GET /cgi-bin/egauge?tot&inst` → XML document with per-register cumulative
  watt-seconds and instantaneous power. Simplest possible integration target.
- **Modbus TCP** (port 502, firmware option) and **BACnet/IP** on some models
  — BMS-friendly.

## Cloud requirement
None, at any point. Setup is via the device's own web UI. (If a meter arrives
with restrictive access settings, the local web UI with physical-button proof
restores access — documented in eGauge KB.)

## Integrations
Home Assistant core `egauge` integration (local_polling, JSON WebAPI);
long history of cacti/grafana scripts against the XML API.

## Open questions
1. Transcribe register model (register names/types, "virtual registers",
   formula registers) from webapi.egauge.net into the repo spec.
2. Document XML API element/attribute names exactly (`<r>` register entries,
   epoch attributes).
3. Confirm per-firmware availability of Modbus TCP (KB says firmware-dependent).

## Safety
CTs + direct mains voltage connections in the panel — installer-grade.
Measurement-only (no switching outputs in normal use).
