# Frontier Silicon / Frontier Smart internet radios (UNDOK/OKTIV platform) — Research Notes

## What it is
Frontier Silicon (now Frontier Smart Technologies) "Venice" Wi-Fi radio
modules power a huge share of internet radios: Hama (IR50, IR110, DIR3110,
DIR355BT), TechniSat (DIGITRADIO 10 IR et al.), Roberts (Stream 94i), Revo,
Medion, Silvercrest (SIRD 14 C2), Auna, Teufel Radio 3sixty (2019), Pinell,
Como Audio, and many more. Retail support for several of these brands is
dead or dying (apps delisted, portal services shut), while the radios
themselves expose a complete local API.

## Local protocol — FSAPI (NetRemote API), documented
- HTTP GET → XML, on **port 80** (some models use **2244**; verify with
  `http://<ip>:<port>/device`).
- Session-based: `GET /fsapi/CREATE_SESSION?pin=1234` returns a session id;
  all reads/writes go through `/fsapi/GET/...` and `/fsapi/SET/...` against a
  node tree (`netRemote.sys.info.friendlyName`, `netRemote.sys.audio.volume`,
  `netRemote.play.*`, `netRemote.sys.mode`, …).
- **Default PIN: 1234** (user-changeable under Main Menu > System settings >
  Network > NetRemote PIN setup).
- Only ONE session controls the device at a time on older firmware — a new
  session invalidates UNDOK (documented limitation in the HA integration).
- Canonical docs/libraries:
  - [flammy/fsapi](https://github.com/flammy/fsapi) — PHP lib + FSAPI.md
    raw request/response documentation (2015+).
  - [MatrixEditor/fsapi-tools](https://github.com/MatrixEditor/fsapi-tools) —
    Frontier Smart firmware tools + NetRemoteApi docs (2023).
  - zhelev/python-afsapi — async Python library.

## Community implementations (confirmed)
- Home Assistant core integration `frontier_silicon` (iot_class:
  local_polling; auto-discovery). Explicitly: any device the UNDOK or OKTIV
  app can see is supported.
- openHAB binding; Node-RED flows; Homey UNDOK/OKTIV app (2026) — all local.

## Discovery
UPnP/SSDP (devices are also DLNA renderers); HA auto-discovery works.

## APK
Not fetched — FSAPI is fully documented; UNDOK/OKTIV apps are thin clients.

## Cloud steps required
None for control. The airable/Frontier portal supplies the station directory
(and is the part that has died for some older devices); direct-URL presets,
DAB/FM, DLNA, and every control function are LAN-local. Note: this is the
**surviving** platform — contrast the Reciva platform (Grace Digital legacy
radios), which died without a local control API.

## Spec work
1. Transcribe the FSAPI node tree (sys/play/nav/caps) from flammy/FSAPI.md.
2. Document port-80-vs-2244 variance and the single-session constraint.
3. Per-brand quirks table (Hama vs TechniSat node availability).

## Safety
LOW — audio only. PIN is 4-digit and often default; recommend noting LAN
exposure.

## Sources (accessed 2026-08-07)
- home-assistant.io/integrations/frontier_silicon
- github.com/flammy/fsapi (FSAPI.md)
- github.com/MatrixEditor/fsapi-tools (2023-12)
- community.homey.app UNDOK/OKTIV thread (2026-05-08)
