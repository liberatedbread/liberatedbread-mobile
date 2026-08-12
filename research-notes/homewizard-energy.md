# HomeWizard Energy (P1 Meter, Energy Socket, kWh Meter, Watermeter) — Research Notes

## What it is
HomeWizard (Netherlands; ACTIVE 2026-08) sells WiFi energy devices:
**P1 Meter** (HWE-P1, plugs into a DSMR smart meter's P1 port),
**Energy Socket** (HWE-SKT, plug with switching + metering),
**kWh Meter** (HWE-KWH1/KWH3, DIN-rail), **Watermeter** (HWE-WTR),
**Plug-In Battery** and **Energy Display**.

## Local API — officially documented by the vendor
Docs: api-documentation.homewizard.com. Two API generations:

### API v1 (HTTP, port 80)
- `GET /api` → product name/type, serial, firmware, `api_version`.
- `GET /api/v1/data` → measurement JSON (P1: `total_power_import_kwh`,
  `total_power_export_kwh`, `active_power_w`, per-phase voltage/current,
  gas/water where attached; Socket: import Wh, active W, relay state).
- `GET /api/v1/telegram` → raw DSMR telegram (P1 Meter).
- `GET/PUT /api/v1/system` → includes `cloud_enabled`; setting
  `{"cloud_enabled": false}` severs the cloud link while local API, switching
  and HA keep working (verified how-to at raspberry.tips, 2026-07).
- Discovery: mDNS `_hwenergy._tcp` (api-documentation.homewizard.com/docs/discovery).

### API v2 (HTTPS, port 443, newer firmware)
- Bearer-token auth; pairing is **local and physical**: `POST /api/user` with
  a client name, then press the button on the device → token issued. No cloud
  account involved in pairing (per vendor getting-started docs; LAVA forum
  confirms flow, 2025-11).
- Discovery: mDNS `_homewizard._tcp`.

## Cloud requirement — one caveat
Enabling the **v1** local API is done in the official HomeWizard app
(Settings → Meters → device → Local API), so the first-time setup flow goes
through the vendor app. After that, cloud can be disabled via the API and the
device is fully local. v2 pairing needs no app account (button press only).

## Integrations
Home Assistant core `homewizard` integration (local_polling) via
python-homewizard-energy; openHAB binding; DSMR Reader plugin path via
`/api/v1/telegram`; evcc meter template.

## Open questions
1. Exact v1 `/api/v1/data` field list per product type (P1 vs Socket vs kWh).
2. Energy Display / Plug-In Battery v2-only endpoints (mDNS table in vendor
   docs says these lack v1).
3. Whether the app account is truly mandatory for the v1 enable-toggle, or a
   local-only provisioning path exists.

## Safety
P1/Socket/Watermeter are plug-in devices — LOW. The DIN-rail kWh Meter is
installer-wired into the distribution board — MEDIUM for that model.
