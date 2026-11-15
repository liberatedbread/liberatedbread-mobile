# Dericam (H502W, S1, M/H series) — Local RTSP/ONVIF Research Notes

## What it is
Dericam was a consumer IP-camera brand selling Smarteye/Wanscam-family
hardware (H502W, S1 "baby monitor" cube, M201W-M801W bullets, H201D/H216W).
Popular on Amazon US/UK ~2015-2020.

**Brand status: dormant/dead.** dericam.com fails to connect as of
2026-08-07 (curl: connection failure, HTTP code 000). Amazon listings are
residual. This is the abandoned-hardware case: local control is the only
path that keeps these units useful.

## Local protocol — confirmed (community + NVR ecosystems)

- **RTSP (H.264 models)**: `rtsp://<ip>:554/11` (main stream; `/12` sub on
  some firmware). home-security-camera.com Dericam guide documents
  `rtsp://admin:admin@192.168.1.188:554/11` including the **static default
  IP 192.168.1.188** — a Wanscam-family fingerprint.
- iSpyConnect lists 71 Dericam models (updated 2026-06): `/ch0_0.h264` RTSP
  variant on H201D/H502/206c; MJPEG-era M-series use
  `/videostream.asf?user=U&pwd=P` (ASF/MJPEG over HTTP, FI89xx-family).
- **ONVIF**: supported on H502W/S1 and later (iSpy ONVIF auto-discovery).
- Default credentials: **admin / admin** (multiple setup guides; JustAnswer
  Dericam thread).

## Cloud status
None needed — these cameras predate the cloud-lock era: local web UI,
local streams, local PTZ. The vendor's disappearance removes nothing except
firmware updates and the (optional) P2P relay.

## Caveats
- admin/admin + static default IP: any LAN neighbor that knows the family
  owns the camera. Change both immediately.
- ASF/MJPEG legacy models need ffmpeg/VLC handling, not plain MJPEG clients.
- Firmware is frozen; assume known Wanscam-family vulnerabilities apply.

## APK
Not fetched — Dericam's app was a Wanscam-family P2P client and the local
RTSP/ONVIF path is already community-verified.

## Sources
- home-security-camera.com Dericam guide: default IP/credentials, RTSP /11
- iSpyConnect Dericam database: 71 models, RTSP/HTTP URLs (updated 2026-06)
- JustAnswer Dericam thread: admin/admin, admin/123456 combinations
- besovideo.com SmartEye platform docs (2021-2022): OEM-family context
- dericam.com connection failure — curl, 2026-08-07
