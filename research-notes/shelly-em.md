# Shelly EM / 3EM / Pro EM family — Research Notes

## What it is
Shelly (Allterco, Bulgaria; ACTIVE 2026-08) WiFi energy meters:
- **Shelly EM** (gen1): single-phase, 2 CT clamps, plus a relay contact.
- **Shelly 3EM** (gen1): 3-phase, 3 CTs (+ neutral clamp support since fw 1.12),
  bidirectional measurement.
- **Shelly Pro EM / Pro 3EM** (gen2): DIN-rail, Ethernet + WiFi, 60 days of
  on-device 1-minute data, scripting. **EM Gen3** also exists.

## Local protocol — vendor-documented, cloud strictly optional
Shelly's design is local-first: the cloud connection is a toggle in the web UI
("Internet & Security") and everything below works with it off.

### Gen1 (EM, 3EM) — docs: shelly-api-docs.shelly.cloud/gen1
- HTTP REST on port 80:
  - `GET /status` → full state incl. `emeters[]` with `power`, `reactive`,
    `voltage`, `pf`, `total`, `total_returned` per channel (Wh).
  - `GET /emeter/0`, `/emeter/0/emeter.csv` (per-channel + CSV export).
  - `GET /settings`, `GET /shelly` (device info/discovery).
- MQTT: device is a client — point it at your own broker; topics
  `shellies/<device-id>/emeter/0/...`.
- CoAP: multicast status to `224.0.1.187:5683` (`cit/s`), also the discovery
  mechanism for gen1.
- Auth: none by default; optional HTTP login can be enabled in settings.

### Gen2/Gen3 (Pro EM, Pro 3EM, EM Gen3) — docs: shelly-api-docs.shelly.cloud/gen2
- JSON-RPC over HTTP `POST /rpc` (`EM.GetStatus`, `EMData.GetStatus`,
  `EMData.GetRecords` for stored minute data) and WebSocket notifications.
- MQTT, outbound WebSocket, local scripts; BLE for provisioning.
- Discovery: mDNS.
- Auth: optional (digest) when a password is set.

## Cloud requirement
None. Provisioning: device AP + local web UI; Shelly app/account optional.
All integrations below run with the device firewalled.

## Integrations
Home Assistant core `shelly` integration (local push/poll, CoAP gen1 / RPC
gen2). openHAB binding, vendor CLI tools (github.com/ALLTERCO/shelly-cli-tools).

## Open questions
1. Spec the gen1 `/status` emeters schema and gen2 `EMData.GetRecords` paging
   into the repo spec from Shelly's API docs.
2. Gen1 relay on the EM (contactor control) — include `relay/0?turn=` commands.

## Safety
Panel/DIN-rail install (3EM wires directly to mains) — installer-grade.
The EM's relay output can switch a contactor: keep it explicitly in the spec.
