# Garadget WiFi Garage Door Controller — Research Notes

## What it is
Garadget (garadget.com, US) is an add-on WiFi controller for existing garage
door openers: a Particle Photon P1-based board with a laser reflectance sensor
(door position), a relay that parallels the wall button, and open-source
firmware (github.com/Garadget/firmware). Company **active** — garadget.com,
community forum and store reachable 2026-08-07.

## Local path (confirmed)
Firmware ≥1.20 (2019-09) adds a **fully local MQTT mode** that can run with
the Particle cloud disabled (`mqon` protocol flags: bit0 = Particle cloud,
bit1 = MQTT broker). Configuration is done over the device's own AP:

1. Hold the `M` button ~3 s → LED blinks dark blue (listening mode).
2. Join the `PHOTON-XXXX` AP, open `http://192.168.0.1/` (SoftAP web UI).
3. Set home WiFi credentials and MQTT broker IP/port; cloud bit can be off.

No cloud account is required for this path — the SoftAP UI is entirely local.
Community guide: vcloudinfo.com "How to configure Garadget for LOCAL MQTT
Only" (2020-07-17). Note: firmware updates historically arrive via Particle
cloud OTA, so reaching ≥1.20 on an old unit may need one cloud contact or a
local USB/Particle-CLI flash.

## MQTT wire protocol (from Garadget/firmware src/nodes/node-mqtt.cpp)
Topic prefix `garadget/<device-name>/`:

| Topic | Direction | Payload |
|---|---|---|
| `garadget/<name>/command` | subscribe | `open`, `close`, `stop`, `get-status`, `get-config`, `reboot` |
| `garadget/<name>/set-config` | subscribe | pipe-delimited config pairs, e.g. `srr=5\|rlp=1000` (max 63 chars/call) |
| `garadget/<name>/status` | publish | `status=closed\|time=...|sensor=..|signal=..` (doorStatus string) |
| `garadget/<name>/config` | publish | full `doorConfig` pipe string (ver, rdt, mtt, rlt, rlp, srr, srt, aev, aot, ans, ane, tzo, nme, mqon, mqip, mqpt, mqto) |
| `garadget/<name>/alert` | publish | JSON, e.g. `{"name":"Home","type":"state","data":"opening"}` |
| `garadget/<name>/LWT` | publish | `Online` / `Offline` (retained) |

Door states: `closed`, `open`, `closing`, `opening`, `stopped`. HA usage
pattern: MQTT cover + a 1-minute `get-status` poll automation.

## Cloud status
Optional, not dead. Default firmware talks to Particle.io (variables
`doorStatus`/`doorConfig`/`netConfig`, function `setState`, events
`state`/`alert`); app depends on it unless MQTT mode is configured.

## APK
- Package `com.garadget.android`, v2.0.6 (versionCode 15), via apkeep
  (APKPure source) 2026-08-07 → `workspace/apks/com.garadget.android.xapk`
- XAPK SHA-256: `3e11a25eff77db317d2162803c537e39905333899c6a59ef4365a545a5fd0abc`
- Not analyzed — protocol already documented by the open firmware source.

## Rating
**Confirmed.** Vendor-published firmware source + multiple community guides.

## Safety
Door is relay-actuated with no entrapment supervision beyond the host opener's
own sensors; the laser sensor only reports position. Keep `stop` and the
offline LWT prominent in any client; treat unattended close carefully.
