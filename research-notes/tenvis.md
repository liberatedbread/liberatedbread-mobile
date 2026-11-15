# Tenvis (JPT3815W, IPROBOT, TH series) — Local CGI/RTSP Research Notes

## What it is
Tenvis (Shenzhen) budget Wi-Fi IP cameras: JPT3815W / JPT3815W-HD, IP602W,
Mini319, IPROBOT2/3, and later TH661/TH692 HD models. Company **active**:
tenvis.com serves "TENVIS Official Website - Security Cameras, IP Cameras"
(checked 2026-08-07), though the legacy models are long out of support.

## Local protocol — confirmed (community + NVR ecosystems)

### MJPEG era (JPT3815W, IP602W, Mini319)
Foscam FI89xx-family clone CGI, port 80 (81 on some):
- MJPEG: `/videostream.cgi?user=U&pwd=P` (iSpyConnect Tenvis DB, 172 models,
  updated 2026-06)
- JPEG: `/snapshot.cgi?user=U&pwd=P`
- PTZ: `/decoder_control.cgi?command=N` (same command map as FI8918W)
- Default credentials: **admin / (blank)** or **admin / admin** depending on
  batch (Synology community JPT3815W thread; Ezlo forum 2014: admin/admin).

### HD era (JPT3815W-HD, IPROBOT3, TH series)
- ONVIF supported (Netcam Studio forum: manager discovers via ONVIF scan;
  iSpy lists ONVIF across the HD range).
- RTSP on port 554 for HD models; exact path varies
  (`/live/ch00_0` family or ONVIF-resolved URI — confirm per unit).
- Default admin / admin (JustAnswer JPT3815W-HD thread, 2017).

## Cloud status
None needed. Tenvis pushed a P2P/app path for the HD models, but every
generation keeps a local web UI and local streams. Legacy units work exactly
as they did at purchase; the company being alive is irrelevant to LAN use.

## Caveats
- 2013-era JPT3815W firmware has published auth-bypass/backdoor research
  (this platform family is notoriously insecure). Never expose to internet;
  change defaults; VLAN.
- The "2013" hardware revision of JPT3815W changed the web UI and some CGI
  paths — check `get_params.cgi` output before assuming the clone map.

## APK
Not fetched — clone-family CGI and ONVIF are already documented; the Tenvis
app is unnecessary for local control.

## Sources
- iSpyConnect Tenvis database: 172 models, CGI/RTSP URLs (updated 2026-06)
- Synology community: JPT3815W config thread
- Ezlo/Vera forum (2014-02): JPT3815W default admin/admin, CGI notes
- Netcam Studio forum (2015-08): JPT3815W-HD MJPEG URL + ONVIF discovery
- JustAnswer (2017-09): JPT3815W-HD default admin password
- tenvis.com homepage fetch, 2026-08-07
