# Logitech Squeezebox family (Lyrion Music Server) — Research Notes

## What it is
Logitech's network audio player line (Slim Devices heritage): Squeezebox
Classic/SB3, Duet (Receiver + Controller), Boom, Radio, Touch, Transporter,
plus the UE Smart Radio (rebadged Radio whose own service Logitech killed —
community firmware converts it back to a Squeezebox Radio). Players are driven
by a self-hosted server: Logitech Media Server (LMS), renamed **Lyrion Music
Server** in 2024, open source (GPL) at
[LMS-Community/slimserver](https://github.com/LMS-Community/slimserver),
actively developed (9.x releases into 2026).

## Why it's the flagship liberation case
- Logitech discontinued the hardware in 2012 but kept the server alive.
- Logitech announced retirement of the last cloud piece, **mysqueezebox.com**,
  in Jan 2024 (shut down Feb 2024) — players that used it for internet
  services now depend entirely on a local LMS, which is fully functional
  without any cloud account. Sources: diyAudio thread (2024-01-27),
  Roon forum (2024-03-20).
- LMS itself is the "rescue": it runs on any LAN host (Docker images
  `lmscommunity/lyrionmusicserver`, piCorePlayer, etc.) and speaks to the
  hardware over fully documented, unauthenticated LAN protocols.

## Local protocol surfaces (all unauthenticated, LAN-scoped)
- **SlimProto — TCP 3483** (server listens, player connects): binary control
  + audio transport for hardware players and squeezelite. Discovery: player
  sends UDP broadcast on **3483/udp** ("NAME"/"DSCO" style probes) or DHCP
  option; server responds, player connects.
- **CLI — TCP 9090** (telnet-style text): `play`, `pause`, `stop`,
  `playlist add <url>`, `mixer volume <0-100>`, `status`, queries, etc.
  Commands prefixed with player MAC; the authoritative reference is the
  LMS CLI documentation shipped with the server.
- **JSON-RPC — HTTP 9000**: POST `{"id":1,"method":"slim.request","params":[<player-mac>,["play"]]}` to `/jsonrpc.js`; same command vocabulary as the
  CLI. Port 9000 also serves the web UI and audio streaming
  (`/stream.mp3`). Optional HTTP basic auth if the user sets it.

## Community implementations (confirmed working, no RE needed)
- Home Assistant core integration `squeezebox` (iot_class: local_push).
- Python `pysqueezebox`; Node libraries; iPeng/Squeezer/Material Skin apps.
- `endegelaende/resonance-server` (2026): clean-room Python reimplementation
  of LMS controlling real Squeezebox hardware — proof the server side is
  fully reimplementable.

## APK
N/A — there is no vendor Android app; control apps (Squeezer, iPeng) and the
web UI are third-party/browser. The server itself is the open-source project.

## Cloud steps required
None for control. Caveats: (1) Squeezebox Radio/Touch initial setup can point
the player at a local LMS directly (UE Smart Radio needs the one-time
community firmware conversion, flashed over USB/SD); (2) streaming services
(Spotify etc.) require per-service accounts inside LMS, but local library,
radio URLs, and control are cloud-free.

## Open questions for a spec
1. Transcribe SlimProto framing (length-prefixed, opcodes `HELO`, `STAT`,
   `STRM`, `audg`, `grfb`/`grfd` display) from slimserver source + community
   docs into a repo-native spec.
2. CLI/JSON-RPC command matrix per player generation (Radio vs Boom display
   differences).
3. Firmware update path for players now that Logitech update servers are
   gone (LMS can serve firmware files locally — document the mechanism).

## Safety
LOW — audio playback only. Note: `mixer volume` accepts 0-100; Transporter
drives external amps, so a spec should keep default volume caps sane.

## Sources (accessed 2026-08-07)
- github.com/LMS-Community/slimserver (active; 9.1.1 issue traffic Mar 2026)
- diyaudio.com/community/threads/mysqueezebox-com-shutting-down.408366 (2024-01-27)
- community.roonlabs.com Squeezebox-after-mysqueezebox thread (2024-03-20)
- github.com/endegelaende/resonance-server
