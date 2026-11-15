# Wanscam / Wansview — Local RTSP/ONVIF Research Notes

## What it is
Shenzhen Smarteye / Shenzhen Wansview Technology consumer Wi-Fi IP cameras,
sold under two brands:

- **Wanscam** — the older brand (HW/JW/AJ-C series, ~2011-2018). Brand is
  dormant: wanscam.com returns 404 as of 2026-08-07. Huge installed base on
  the used market; many units are FI89xx-clone MJPEG models or early H.264.
- **Wansview** — the successor/active brand (K2/K3/K5, Q3/Q5/Q6, NCM/NBC,
  W-series). Company active: wansview.com up 2026-08-07 (rate-limited),
  GALAYOU trademark registered 2022 by Shenzhen Wansview Technology, and the
  company appears as defendant in a 2026 W.D. Texas patent case.

## Local protocol — confirmed (community + NVR ecosystems)

### Wansview HD models (K/Q/NCM series)
- RTSP: `rtsp://<ip>:554/live/ch0` (1080p main), `/live/ch1` (480p sub).
  Confirmed for K3 1080p (CamioCam/rtsp issue #187, 2018-10, OUI F0:85:C1)
  and Q5 (IP Cam Talk thread, 2022-05). iSpyConnect lists 134 Wansview
  models (updated 2026-06).
- ONVIF: supported on K3/Q5 and most current models (per iSpy/GeniusVision).
- Default credentials: **admin / 123456** (K3 user manual; GeniusVision
  NCL616W entry). HTTP web UI on port 80/81/82 depending on model.
- Some models have an HTTP CGI set (`/web/cgi-bin/...` varies by firmware) —
  RTSP/ONVIF is the reliable common denominator.

### Wanscam legacy models
- H.264 HW series: RTSP `rtsp://<ip>:554/live/ch00_0` (main), `ch00_1` (sub);
  ONVIF on later units; default admin / 123456.
- MJPEG era (JW000x, old AJ): Foscam FI89xx-family CGI — `videostream.cgi`,
  `snapshot.cgi`, `decoder_control.cgi`; default admin / admin
  (CameraFTP Wanscam guide). iSpyConnect lists 452 Wanscam models (2026-06).

## Cloud status
None needed for LAN use. The Wansview app's cloud-storage subscription and
P2P relay are optional; cameras can be provisioned over Ethernet + web UI or
via the app in direct-LAN mode, and stream via RTSP/ONVIF with no account.
Dormant Wanscam-branded units lose nothing — their web UI and RTSP are local.

## Caveats
- Default admin/123456 on a device with P2P enabled out of the box is a real
  exposure: change password, disable P2P/UPnP in the web UI, isolate on VLAN.
- RTSP path differs between generations (`/live/ch0` vs `/live/ch00_0`) —
  try both; ONVIF discovery settles it.
- Per-model firmware variance: verify RTSP/ONVIF is present on the specific
  unit before recommending; recent ultra-budget models occasionally ship
  reduced local interfaces (community reports, not systematic).

## APK
Not fetched — RTSP/ONVIF paths are community-confirmed and no APK is needed
for local control. Wansview Play Store app exists if deeper CGI RE is wanted
later.

## Sources
- CamioCam/rtsp issue #187 (2018-10-17): K3 RTSP URL template, OUI F0:85:C1
- IP Cam Talk (2022-05-31): Q5 RTSP + ONVIF, admin/123456
- Wansview K3 user manual (itsmanual.com, 2022): default admin/123456
- GeniusVision NCL616W entry: admin/123456, ONVIF
- CameraFTP Wanscam guide: legacy default admin/admin
- iSpyConnect Wansview (134 models, 2026-06) / Wanscam (452 models, 2026-06)
- furm.com trademark record: GALAYOU, Shenzhen Wansview Technology, reg. 2022
- PatSnap (2026-07): KT Imaging v. Wansview & Smarteye litigation listing
- wanscam.com 404 / wansview.com up — curl, 2026-08-07
