# OpenEnergyMonitor emonPi / emonBase / emonTx — Research Notes

## What it is
OpenEnergyMonitor (Megni Ltd, UK; ACTIVE 2026-08) — fully open hardware +
software energy monitoring ecosystem:
- **emonTx** (V3/V4): battery/AC-powered CT measurement node, 433 MHz RFM69
  radio to a base station.
- **emonBase / emonPi**: Raspberry Pi base running the emonSD stack
  (emonHub + emonCMS + Mosquitto), receiving nodes over radio or serial.

## Local APIs — documented open source
Docs: guide.openenergymonitor.org; docs.openenergymonitor.org.

- **emonCMS HTTP REST** on the base station (`http://emonpi.local/emoncms`):
  - Input: `POST/GET input/post.json?node=emontx&json={power1:100}&apikey=...`
  - Feeds: `feed/list.json`, `feed/data.json?id=<n>&start=&end=&interval=`
  - Per-account read-only and write API keys; per-device keys supported.
- **Local MQTT**: Mosquitto on port 1883. emonHub publishes per-key topics
  `emon/<nodename>/<key>` (e.g. `emon/emontx4/power1`). Default credentials
  `emonpi` / `emonpimqtt2016` are **public and must be changed**
  (guide.openenergymonitor.org/technical/mqtt).
- mDNS hostname `emonpi.local`.

## Cloud requirement
None — emoncms.org is an optional hosted twin; the whole stack runs on the
base station. Provisioning and all config via the local web UI.

## Integrations
Home Assistant core `emoncms` integration accepts a local URL (HA community,
2018-03); or subscribe to the local MQTT broker directly — the OEM-recommended
path for real-time data (OEM community, 2023-03, MQTT HA discovery work).

## Open questions
1. Spec the RFM69 node→base packet format (emonLibCM payload structs) if the
   radio hop itself is in scope; otherwise treat emonHub/emonCMS as the
   boundary and document REST + MQTT schemas.
2. EmonESP WiFi nodes (ESP8266 serial→WiFi bridge) expose their own local
   HTTP API (`/status`) — worth a subsection.

## Safety
emonTx/emonPi use clip-on CTs (non-invasive) but sit in/near the panel —
care during install. Measurement-only.
