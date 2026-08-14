# Y-cam (White/Black/Knight/Bullet HD/Cube HD) — Local RTSP/MJPEG Research Notes

## What it is
Y-cam Solutions Ltd (UK) Wi-Fi IP cameras. Two distinct generations:

- **Classic line** (~2007-2013): Y-cam White/Black (S), Knight S, Bullet HD
  720/1080, Cube HD 720/1080. Full local web UI, local streams — proper LAN
  cameras.
- **Cloud line** (~2014-2018): HomeMonitor, Evo. Tied to the Y-cam cloud;
  a 2016 Synology-forum buyer-beware thread confirms these could not be
  operated locally ("completely locked in to their own cloud based service").
  Y-cam retired the web portal 2020-03-31, going app-only (EEVblog, 2020-07).

**Company status: dead.** Crunchbase lists Y-cam Solutions Ltd "Operating
Status: Closed". As of 2026-08-07, y-cam.com serves an unrelated Shopify
storefront ("ERA Protect | Home Security Solutions") — domain reused. The
HomeMonitor/Evo cloud service is gone with it.

## Local protocol — confirmed, classic line only

From the iSpyConnect Y-cam database (22 models, updated 2026-06), vendor
manuals, and a 2011 curl-project RTSP digest-auth trace against a Bullet:

- **RTSP (port 554)**: `/live_mpeg4.sdp` (White/Black/Bullet/Cube MPEG4),
  `/live_h264.sdp` / `/live_h264_1.sdp` (Bullet HD), `/live/0/h264.sdp`
  (Cube HD), `/live/0/onvif.sdp` (ONVIF-exposed stream on Bullet/Cube HD).
- **ONVIF**: Bullet HD and Cube HD families support ONVIF discovery.
- **MJPEG/JPEG over HTTP**: `/stream.jpg` (MJPEG), `/snapshot.jpg?user=U&pwd=P`
  (JPEG), `/stream.asf` on the oldest White/Black.
- **Default credentials**: **admin / 1234** — stated in every Y-cam manual
  (Bullet HD 1080 quick-start, Knight SD manual, White SD manual).

The curl trace shows RTSP digest auth working directly against
`rtsp://admin:1234@<ip>:554/live_mpeg4.sdp` with server banner
`Y-CAM:BULLET` — no proxy, no cloud.

## Cloud status
Classic line: none — web UI, RTSP, and ONVIF are entirely local; first-time
setup is Ethernet + browser. These units are fully usable today.
Cloud line (HomeMonitor/Evo): dead with the company; treat as e-waste
unless a local stream turns up (unverified — iSpy lists HomeMonitor HD Pro
with `/stream.jpg`, so one model may have a local MJPEG fallback; hypothesis).

## Caveats
- Buy/keep only the classic line; verify the model number against the
  classic list before acquiring.
- admin/1234 is public knowledge; change it. Cleartext HTTP; VLAN.
- No firmware updates since company closure (~2018).

## APK
Not applicable/fetched — classic line is browser-driven; cloud-line app is
dead with its service.

## Sources
- iSpyConnect Y-cam database (22 models, RTSP/HTTP URLs, updated 2026-06)
- Y-cam Bullet HD 1080 quick-start guide PDF (use-ip.co.uk): admin/1234
- Y-cam Knight SD / White SD user manuals: admin/1234
- curl mailing list (2011-06): live RTSP digest session, Y-CAM:BULLET, :554/live_mpeg4.sdp
- Synology forum "Buyer Beware - Y-Cam Cameras" (2016-02): cloud-line lock-in
- EEVblog (2020-07): web portal retired 2020-03-31, app-only
- Crunchbase: Y-cam Solutions Ltd, Operating Status Closed
- y-cam.com now serves "ERA Protect" Shopify store — curl, 2026-08-07
