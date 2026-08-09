# Ulanzi TC001 Smart Pixel Clock (AWTRIX 3) — Research Notes

## What it is
Ulanzi TC001: €40-class desktop pixel clock, 32×8 RGB LED matrix on an ESP32,
USB-C, buzzer, buttons. Ulanzi (Shenzhen photo-accessory maker) alive and
selling as of 2026-08-07. Stock firmware is bound to the Ulanzi phone app and
its cloud (weather etc.) — the interesting path is the community replacement
firmware.

## Local path — confirmed (AWTRIX 3 community firmware)
AWTRIX 3 (github.com/Blueforcer/awtrix3, docs blueforcer.github.io/awtrix3)
is a mature open-source ESP32 firmware for the TC001 (and DIY matrices):

- **Flash over USB-C from the browser** (WebSerial installer) — no tooling,
  no account; erases the cloud-bound stock firmware.
- **Local control, two documented channels**:
  - HTTP REST: `POST http://<ip>/api/<endpoint>` — e.g. `/api/notify`
    (text + 8×8 icon/animation + sound + duration), `/api/custom` (persistent
    custom apps), `/api/power`, `/api/brightness`, `/api/moodlight`,
    `/api/settings`, `/api/stats`, `/api/loop`.
  - MQTT: topics `<prefix>/notify`, `<prefix>/custom/<app>`, `<prefix>/power`,
    `<prefix>/settings`, status on `<prefix>/stats` — Home Assistant
    auto-discovery built in.
- On-device web UI for configuration; icon gallery reused from LaMetric.
- No cloud of any kind after flashing (NTP/weather optional and user-chosen).

## Existing implementations
- Home Assistant via MQTT auto-discovery (native); notify-service examples
  widely published (raspberry.tips tutorial 2026-07-13; ulanzi.de guide
  2026-06; commander1024.de 2023-11).
- AWTRIX 3 has its own documented API surface (docs site, "API MQTT/HTTP").

## What needs cloud
Nothing after flashing. Stock firmware: Ulanzi app + vendor cloud for weather
and account features — replaced, not preserved, by AWTRIX (flash back is
possible via Ulanzi's flasher if ever wanted).

## APK
Ulanzi app irrelevant once reflashed. Not fetched.

## Open questions
1. Stock-firmware local protocol (if any) — undocumented; moot given AWTRIX.
2. TC001 hardware revisions (battery vs non-battery) all supported? (Docs say
   TC001 supported; verify sub-revisions during spec work.)
