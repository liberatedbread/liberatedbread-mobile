# Neato Botvac Connected / D3–D7 — Research Notes

## What it is
Neato Robotics (acquired by Vorwerk 2017, shut down 2023) laser-guided robot
vacuums: Botvac Connected (2015), D3/D3 Pro, D4, D5, D6, D7. Newer D8/D9/D10
(2020) use a different board/firmware and are a separate, worse story.

## Why it's abandoned (dated sources)
- Neato Robotics ceased operations April 2023; Vorwerk promised cloud until
  2028, then reversed: support.neatorobotics.com announcement (2025-10-06)
  phased out all Neato cloud services during Q4 2025. By December 2025 the app
  showed a shutdown message; robots reduced to button-only operation
  (no schedules, no maps, no no-go lines).
  (vacuumwars.com 2025-12-29; wespeakiot.com 2026-06-04; Trustpilot reports
  Dec 2025)
- Final stock firmware: 4.5.3_189 for D3–D7. Images with non-expired
  certificates are archived at github.com/RobertSundling/neato-botvac
  (firmware .bin SHA-256
  `3d36076fbf3c196ef452b81d54857c75c17ac6eca24ef614aff27a8decc56ef8`).

## Local paths (the rescue)

### 1. Stock firmware local HTTPS endpoint (port 4443)
The robot itself serves HTTPS on TCP 4443 on the LAN (and on its setup AP).
`curl -k --ciphers ALL:@SECLEVEL=0 https://<robot-ip>:4443/info` returns
version info (old TLS stack — needs lowered OpenSSL SECLEVEL). Documented in
Quiwy/neato-connected setup docs (2025-12). Extent of the local API beyond
`/info` is under-explored — spec opportunity.

### 2. UART debug port + ESP32 bridge (fully local control)
All D3–D7 (and even non-WiFi Botvacs) expose the classic Neato text command
interface on a UART: USB port at the dustbin (Connected) or debug pads under
the bumper (115200 8N1; try 500000 baud on some units). Commands like
`GetVersion`, `Clean`, `PlaySound`, `GetCharger` are the same serial API from
the XV era. Two active community bridges make this a WiFi-local API:
- **renjfk/OpenNeato** (2026, MIT, beta): ESP32-C3/S3 wired to the debug port;
  serves a local web UI (dashboard, manual drive with live LIDAR map, 7-day
  scheduler, cleaning history) at `http://neato.local`. No cloud, no account.
  D3–D7 only.
- **Quiwy/neato-connected** (2025-12): ESPHome firmware + Home Assistant card
  over the same UART; start/stop, settings, scheduling via HA automations.
  Confirmed D3/D4/D5/D6/D7 on firmware 4.5.3; return-to-dock and manual
  driving in beta; ROS2-based zone cleaning planned.

### 3. D8/D9/D10 — currently a dud
Different platform; debug serial is password-locked, so neither bridge works.
A "local fake cloud" effort (DNS redirect + local API server) is in progress
in RobertSundling/neato-botvac Discussion #18 (2026-02) but blocked on
TLS/CA pinning on port 3443. Do not buy D8+ for local control.

## APK
- **Package**: `com.neatorobotics.android` — still fetchable via apkeep
  (Google Play mirror) as of 2026-08-07 despite the shutdown.
- APK SHA-256: `9edcc603f84074beed105b8b4019099e65ef6749f3a2800d145994c4a6472b02` (41.7 MB)
- The app is non-functional without the cloud, but useful for RE of the
  robot↔cloud API (relevant to the fake-cloud effort and the :4443 endpoint).

## What needs cloud
Nothing for paths 1–2 (D3–D7). UART bridges are account-free by construction.
Firmware recovery images are community-archived (RobertSundling repo), so even
reflashes avoid the dead vendor CDN.

## Open questions
1. Full surface of the stock :4443 HTTPS API (beyond `/info`) — worth a
   static pass over the fetched APK + on-device probing.
2. D8/D9/D10 fake-cloud TLS bypass status (Discussion #18).
3. Neato serial command set coverage vs. the cloud-only features (maps,
   no-go lines — in progress in neato-connected stage 2).

## Safety
Li-ion battery + moving brush; manual-drive modes in OpenNeato include
wheel-lift/stall warnings and a disconnect watchdog — keep those.
