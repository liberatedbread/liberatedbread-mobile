# Foscam FI89xx (VGA/MJPEG) & FI98xx (HD) — Local CGI/RTSP Research Notes

## What it is
Foscam (Shenzhen Foscam Intelligent Technology) consumer Wi-Fi IP cameras.
Two legacy families dominate the second-hand market:

- **FI89xx** (FI8904W/05W/08W/09W/10W/18W/19W/20W, ~2008-2012): VGA MJPEG
  cameras, many with PTZ. The original "clone platform" — dozens of rebadges
  (Apexis, Wanscam MJPEG era, EasyN) share the same CGI.
- **FI98xx** (FI9821W/26W/31W, FI9803P/04W/05W, ~2013-2016): 720p/1080p H.264
  cameras with a newer XML CGI and RTSP.

Company is **active**: foscam.com reachable 2026-08-07. These legacy lines get
no firmware updates, which is exactly why the documented local API matters —
no cloud is required at any point.

## Local protocol — confirmed (vendor-documented + community)

### FI89xx family (MJPEG CGI, port 80 default)
Vendor CGI guide circulated since ~2010 (`FI8918W-CGI-Commands.pdf`; Jeedom
community mirror). Auth = `user`/`pwd` URL params or HTTP Basic.
Default credentials: **admin / (blank)** (FI8918W user manual, foscam.es PDF).

| Endpoint | Function |
|---|---|
| `/videostream.cgi?user=&pwd=` | MJPEG live stream |
| `/snapshot.cgi?user=&pwd=` | JPEG snapshot |
| `/decoder_control.cgi?command=N` | PTZ (0=up,2=down,4=left,6=right; +1 stop), IR LED (94/95) |
| `/get_status.cgi` | Device/alarm status (`var` JS format) |
| `/set_alarm.cgi`, `/camera_control.cgi` | Alarm config, resolution/flip |
| `/get_params.cgi`, `/get_misc.cgi` | Full config dump |

No RTSP on these — MJPEG only. ZoneMinder has a dedicated FI8918W control
script; openHAB 1 wiki documents the full command set.

### FI98xx family (XML CGI + RTSP)
- CGI: `http://<ip>:88/cgi-bin/CGIProxy.fcgi?cmd=<command>&usr=<u>&pwd=<p>`
  — XML responses. Commands: `snapPicture2`, `getDevState`, `ptzMoveUp/...`,
  `setMotionDetectConfig`, `getIPInfo`, etc. (Foscam "IPCamera CGI User Guide",
  HD SDK PDF; used by Home Assistant and openHAB).
- RTSP: `rtsp://<ip>:88/videoMain` and `/videoSub` (port 554 on later
  firmware/models). Many models also expose ONVIF (discovery port 888/8080).
- Default: admin / (blank) on early units; later firmware forces a password
  change on first login.

### Home Assistant
Official `foscam` integration, local polling — live stream, PTZ actions,
IR/white light, siren, flip, motion config (home-assistant.io/integrations/foscam,
fetched 2026-08-07). Older FI89xx work via HA's generic MJPEG camera.

## Cloud status
None needed. Foscam Cloud (subscription recording) and the P2P relay are
optional add-ons. First-time setup is local: Ethernet + web UI, or the
Foscam app's direct-LAN mode. A camera that never touches the internet is
fully functional.

## Security caveats (important for spec doc)
- Unpatched legacy firmware: FI89xx-era units have multiple published CVEs
  (auth bypass, command injection). Treat as hostile: isolate on an IoT VLAN,
  never port-forward.
- Always change the blank default password; CGI auth is cleartext HTTP.

## APK
Not fetched — the local protocol is vendor-documented and widely implemented;
the Foscam app is not needed for control. `apk_acquired: false` (not needed).

## Sources
- Foscam FAQ #128, MJPEG CGI per model family (foscam.com/faqs/view.html?id=128)
- FI8918W user manual (default admin/blank) — foscam.es PDF mirror
- Foscam IPCamera CGI User Guide (HD) — community.jeedom.com PDF mirror
- ZoneMinder wiki: Foscam FI8918W control config
- openHAB 1 wiki: Foscam IP Cameras (getDevState polling, CGIProxy.fcgi on :88)
- Home Assistant foscam integration docs (fetched 2026-08-07)
- iSpyConnect Foscam database, 429 models (updated 2026-06)
