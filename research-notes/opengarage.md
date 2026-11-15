# OpenGarage — Research Notes

## What it is
OpenGarage (OpenThings / rayshobby) is an **open-hardware** WiFi garage door
controller: ESP8266 board + ultrasonic distance sensor (door position and
vehicle presence) + relay. Sold assembled at opengarage.io; full schematic
and firmware source published. Vendor **active** — opengarage.io and
openthings.io reachable 2026-08-07.

## Local path (confirmed, vendor-documented)
Fully local **REST/HTTP GET API** on port 80 — vendor publishes an API
document with each firmware (e.g. "OpenGarage Firmware 1.0.4 API document"
on GitHub; current firmware 1.2.x). Verified against the HA `opengarage`
integration (iot_class: local_polling) and pyOpenGarage source
(github.com/Danielhiversen/pyOpenGarage), 2026-08-07.

| Endpoint | Purpose |
|---|---|
| `GET /jc` | JSON status: `door` (0/1), `dist` (cm), `vehicle`, `rcnt`, `fwv`, ... |
| `GET /jo` | JSON options (thresholds, device key, etc.) |
| `GET /ja` | JSON all (status + options + logs) |
| `GET /cc?dkey=<key>&click=1` | toggle door (relay pulse) |
| `GET /cc?dkey=<key>&open=1` | open only (no-op if already open) |
| `GET /cc?dkey=<key>&close=1` | close only (no-op if already closed) |
| `GET /cc?dkey=<key>&reboot=1` | reboot; `&apmode=1` returns to AP provisioning |
| `GET /db` | log download (CSV) |

- **Auth**: single shared device key, factory default **`opendoor`**
  (documented; Jeedom howto and pyOpenGarage). No per-user accounts.
- **MQTT**: firmware also supports MQTT (community PR merged early; forum
  thread opengarage.io/forums/topic/mqtt-and-og, 2016-10) for push updates.
- Provisioning is local: device AP + embedded web UI at 192.168.100.1.

## Cloud status
Optional only: Blynk cloud provides the remote phone UI and notifications.
Works 100% offline via the web UI / REST / MQTT without any account.

## APK
No companion APK — vendor UI is the embedded web page plus the (cloud) Blynk
app; both unnecessary on the local path. N/A for apkeep.

## Rating
**Confirmed** — open hardware/firmware + vendor API doc + HA integration.

## Safety
MEDIUM — relay pulse actuates the door; ultrasonic sensor reports position/
vehicle but is not a safety edge. Default key `opendoor` is public
knowledge: **changing the device key is mandatory** if the LAN is not
trusted.
