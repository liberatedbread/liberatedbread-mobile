# Bose SoundTouch speakers — Research Notes

## What it is
Bose's Wi-Fi multiroom speaker line (2013–2017): SoundTouch 10/20/30,
SoundTouch 300 soundbar, SA-5 amplifier, Wave SoundTouch IV, Lifestyle
550/600/650 systems, SoundTouch wireless link adapter.

## Dead-ecosystem timeline (the unusual part: vendor cooperated)
- Oct 2025: Bose announced SoundTouch end of support — cloud shutdown
  initially 2026-02-18, speakers would lose app + streaming services.
- Jan 2026: after customer backlash, Bose (a) delayed shutdown to
  **2026-05-06**, (b) published the complete **SoundTouch Web API as a public
  PDF** (31 pages: HTTP endpoints + WebSocket protocol), and (c) promised an
  app update that keeps local-only functions (grouping, playback control)
  working after the servers die.
- Sources: Hackaday (2026-01-09), It's FOSS (2026-01-09), Korben (2026-03-09),
  bose.fandom.com SoundTouch app alternatives (2026-03-18). API PDF:
  assets.bosecreative.com/.../SoundTouch-Web-API.pdf ("2026.4.1 SoundTouch
  Web API").

## Local protocol (vendor-documented)
- **REST over HTTP, port 8090**, XML bodies. Core endpoints (long community-
  known, now official): `/info`, `/now_playing`, `/volume`, `GET/POST /volume`,
  `/sources`, `/select`, `/presets`, `/key` (press/release: PLAY, PAUSE,
  NEXT_TRACK, PREV_TRACK, POWER, MUTE, VOLUME_UP/DOWN), `/name`, `/bass`,
  `/zone` (multiroom grouping).
- **WebSocket on port 8080** ("gabbo" notification protocol) for realtime
  now-playing/volume/zone updates.
- Discovery: SSDP (UPnP `urn:schemas-upnp-org:device:MediaRenderer`) and mDNS;
  speakers also expose a setup web server.
- Auth: none on the LAN API.

## Community implementations (pre-date the vendor doc)
- Home Assistant core integration `soundtouch` (iot_class: local_polling) —
  in core for years, uses libsoundtouch.
- Fresh post-announcement SDKs: `captivus/bose-soundtouch` (Python),
  `cssinate/bose-soundtouch` (JS) — both written against the 8090 REST API.

## APK
Not fetched — the wire protocol is now vendor-documented; the app is
unnecessary for a spec. (The 2026 local-mode app update is optional.)

## Cloud steps required
None for control. After 2026-05-06 the Bose account/cloud dies; per the
vendor, local API + truncated app keep working. Presets and music-service
integration were cloud-coupled and are lost; local sources (AUX, Bluetooth,
DLNA, stored internet-radio URLs via API) keep working.

## Spec work
Transcribe the official PDF: endpoint table, XML schemas, WebSocket gabbo
message types, `/key` codes, zone/group semantics. Lowest-effort confirmed
entry in this batch — documentation is first-party.

## Safety
LOW — audio only.

## Sources (accessed 2026-08-07)
- hackaday.com/2026/01/09/bose-soundtouch-smart-speakers-get-an-open-source-lifeline/
- assets.bosecreative.com SoundTouch-Web-API.pdf (2026-01-07)
- github.com/captivus/bose-soundtouch, github.com/cssinate/bose-soundtouch
- home-assistant.io/integrations/soundtouch
