# Vstarcam (C-series, Eye4 platform) — Local RTSP/ONVIF Research Notes

## What it is
VStarcam (Shenzhen Vstarcam Technology) consumer Wi-Fi IP cameras: C7824WIP
and successors (C24S/C26S/C29S, C38S, T-series), all tied to the vendor's
Eye4 app/P2P cloud. Company **active**: vstarcam.com up, SDK download page
dated 2024-12 (checked 2026-08-07).

## Local protocol — confirmed (vendor-documented RTSP)

- **RTSP (vendor SDK doc)**: `rtsp://<user>:<pass>@<ip>:554/live/ch00_0`
  (main) and `/live/ch00_1` (sub). The vendor SDK page (vstarcam.com/sdk-download,
  2024-12) documents exactly this format and states the default camera
  password is **888888** (user `admin`).
- **ONVIF**: supported on newer models; the C7824WIP generation does **not**
  support ONVIF (koshka.ddns.net watchdog writeup, 2016-11). Verify per model.
- **HTTP web UI**: port 81 (some models 80), admin / 888888
  (same watchdog writeup; greemvas.ru setup guide).
- PTZ models expose ONVIF PTZ where ONVIF exists; otherwise proprietary HTTP
  CGI under the web port (undocumented, model-variant).

## Cloud status
Eye4 (P2P relay + optional cloud recording) is the vendor path, but cameras
keep full local web UI + RTSP with no account. Provisioning is local
(Ethernet or AP-mode onboarding in Eye4; the app works in LAN-direct mode).
If Eye4 cloud died tomorrow these cameras lose nothing on the LAN.

## APK
- **Package**: `vstc.vscam.client` (Eye4)
- **Source**: apkeep (Google Play mirror), fetched 2026-08-07
- **APK SHA-256**: `fda0e34fe2e461ddad707db7d2babb7781389c861491a43a9224a508dc111e7b`
- **Size**: ~99 MB (bundles P2P native libs)
- Not decompiled — RTSP is vendor-documented; APK only needed if the
  proprietary PTZ/config CGI is ever targeted.

## Caveats
- Default admin/888888 + enabled P2P: change password, disable UPnP, VLAN.
- ONVIF presence is generation-dependent (C7824WIP: no; later C-series: yes).
- RTSP auth is cleartext; some firmwares also expose ONVIF without auth —
  check with an ONVIF scanner before trusting segmentation.

## Sources
- VStarcam SDK download page (vstarcam.com/sdk-download, dated 2024-12,
  fetched 2026-08-07): RTSP URL format, default password 888888
- koshka.ddns.net Vstarcam watchdog (2016-11-28): admin/888888 web UI,
  C7824WIP has no ONVIF, newer models do
- Moonware/Netcam Studio forum (2016-07): C7824WIP ONVIF discussion
- Camlytics/iSpyConnect Vstarcam databases: RTSP on 554 across model range
- apkeep fetch log, workspace/apks/vstc.vscam.client.apk, 2026-08-07
