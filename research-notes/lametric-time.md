# LaMetric Time — Local API Research Notes

## What it is
LaMetric Time (2014 Kickstarter) and LaMetric Sky: WiFi pixel-display clocks
(37×8 LED matrix + speaker) for ambient info/art. Company alive and selling
(lametric.com, as of 2026-08-07). Stands out in this category for having a
**vendor-documented local API**.

## Local interface — confirmed (vendor-documented)
Official docs: lametric-documentation.readthedocs.io (source:
github.com/lametric/Documentation).

- Device API on the LAN: **port 8080 (HTTP)** and **port 4343 (HTTPS)**.
- Auth: HTTP Basic, user `dev`, password = device API key.
- Base path `/api/v2/`:
  - `GET /api/v2/device` — device info, name, serial, WiFi, BT state
  - `GET|PUT /api/v2/device/display` — brightness (auto/manual), screensaver
  - `GET|PUT /api/v2/device/audio` — volume
  - `GET|PUT /api/v2/device/bluetooth`
  - `GET|PUT /api/v2/device/wifi`
  - `POST /api/v2/device/notifications` — push a notification: text + icon
    (8×8 frames, including animation), sound, priority, lifecycle —
    this is the main content channel
  - `GET /api/v2/device/apps` + per-app widget endpoints
    (`/api/v2/device/apps/<app>/widgets/...`) — activate apps, set widget
    data (e.g. clock face), run custom "My Data DIY" apps locally
- Discovery: IP via DHCP; docs also describe cloud-assisted device lookup.
  API key obtained from developer.lametric.com "My Devices" (tied to the
  paired device).

## Existing implementations
- Home Assistant core `lametric` integration (local push/polling) —
  notifications, brightness, volume, app switching.
- Homey community app, FHEM module, numerous Python libs (lametric-python).

## What needs cloud
- **One-time**: device pairing via the LaMetric app (account) and retrieving
  the device API key from the developer portal. After that the local API is
  self-sufficient on the LAN.
- App-store "indicator apps" and their data sources are cloud; custom DIY
  apps + notifications are fully local.
- If LaMetric's cloud dies: already-paired devices keep working via local
  API; new-device pairing is the risk.

## APK
Companion app exists but unnecessary — protocol is vendor-documented.
Not fetched.

## Open questions
1. Can the device API key be read from the device itself (pairing-mode AP or
   BLE setup channel) to remove the one-time portal dependency?
2. Sky (triangular light panels) local-API coverage vs Time.
