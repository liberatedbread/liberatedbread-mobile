# IoTaWatt — Research Notes

## What it is
IoTaWatt is an open-hardware, open-firmware WiFi home energy monitor
(ESP8266-based) with 14 CT input channels and one voltage reference, sold by
IoTaWatt, Inc. (Bob Lemaire) via shop.iotawatt.com. Schematics and firmware are
public (github.com/boblemaire/IoTaWatt). Manufacturer ACTIVE as of 2026-08.

## Why it's the gold standard for local
The device runs its own web server: all configuration, real-time status, and
the Graph+ history visualizer are served directly from the device. No account,
no cloud, no companion app — the vendor's tagline is literally "Open system,
private data" (iotawatt.com). Cloud uploaders (Emoncms, InfluxDB, PVoutput)
exist but are strictly optional and configured per-user.

## Local API (vendor-documented)
Docs: docs.iotawatt.com (Status, Query API pages).

- Discovery: mDNS — `iotawatt.local` (configurable hostname).
- Real-time: `GET http://iotawatt.local/status?inputs=yes&outputs=yes&stats=yes`
  → JSON array of inputs/outputs with `Vrms`, `Watts`, `PF`, `Hz`, etc.
  (HA REST-sensor pattern confirmed in IoTaWatt community, 2019-10).
- History: Query API `GET /query?show=series` lists series;
  `GET /query?select=[time.unix,in1.Watts]&begin=-1h&end=s&group=all`
  returns JSON or CSV from the on-device datalog (docs.iotawatt.com/en/master/query.html).
- Config: the whole setup UI is local HTTP on port 80.

Auth: none by default; an optional admin password can be set in the device
config UI. Treat the LAN as the trust boundary.

## Cloud requirement
None, end to end. Initial provisioning is local: the device boots an AP
(`iotawatt`), you join Wi-Fi via its captive web UI, done. Works fully with
WAN blocked.

## Integrations
Home Assistant core `iotawatt` integration (local_polling). A forked HACS
variant (kuralabs/iotawatt_ha, 2023) fixed upstream breakage.

## Open questions
1. Transcribe exact `/query` parameter grammar and `/status` field list into
   the repo spec from docs.iotawatt.com.
2. Rate limits on rapid polling of the ESP8266 web server (community suggests
   5 s poll intervals are safe).

## Safety
CT clamps + mains voltage reference installed inside the breaker panel —
installer-grade work. The device itself is measurement-only (no switching).
