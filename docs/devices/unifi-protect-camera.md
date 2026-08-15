# Ubiquiti UniFi Protect Camera

> **Status**: Complete (discovery + RTSP transport hardware-verified 2026-08-14; feed exposed)
> **Protocol**: Ubiquiti discovery (UDP 10001) + RTSP via the NVR
> **Manufacturer**: Ubiquiti Inc.
> **Manufacturer Status**: Active — local live feed, no Ubiquiti cloud

## Overview

UniFi Protect cameras (UVC G3/G4/G5/G6, AI series, doorbells) are adopted to a
Protect NVR. We **discover** them with the Ubiquiti UDP-10001 protocol and can
**show a live feed** with no Ubiquiti cloud — the stream is served by the NVR,
not the camera, and RTSP is off until enabled per-camera in Protect.

Verified live 2026-08-14: the whole camera fleet enumerated by model over
UDP 10001 (G3 Dome, AI 360, G4 Pro/Dome, G6 Bullet, G4 PTZ, G3 Instant, G4
Doorbell), and the UNVR's RTSP server confirmed live — ports 7447 (RTSP) and
7441 (RTSPS) open, and an RTSP `OPTIONS` returned `200 OK`,
`Server: Media Server (www.ui.com)`, advertising `DESCRIBE`/`PLAY`/`SETUP`.

## Feed

| Property | Value |
|----------|-------|
| Enable | Per-camera, per-quality (High/Medium/Low) in UniFi Protect → camera → Settings → Advanced → RTSP |
| Served by | the **NVR**, not the camera |
| RTSP | `rtsp://<nvr-ip>:7447/<streamId>` (preferred for phone players; force TCP) |
| RTSPS | `rtsps://<nvr-ip>:7441/<streamId>?enableSrtp` (TLS+SRTP, self-signed — many players fail; opt-in) |
| `streamId` | opaque per-quality token (`rtspAlias`) — it IS the secret, no user/pass on the URL |
| Get token | paste the Protect-shown URL, or `GET /proxy/protect/api/bootstrap` after a local NVR login → `cameras[].channels[].rtspAlias` where `isRtspEnabled` |

Camera control (PTZ, settings) is out of scope — this is feed + identity only.
**Admin**: `https://<nvr-ip>/`.

## References

- <https://github.com/hjdhjd/unifi-protect>
- <https://github.com/uilibs/uiprotect>
- <https://help.ui.com/hc/en-us/articles/217879287-UniFi-Protect-RTSP-Streaming>
