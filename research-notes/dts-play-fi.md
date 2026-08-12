# DTS Play-Fi (Phorus) speakers — Research Notes

## What it is
DTS Play-Fi (Xperi; acquired Phorus in 2014) is the closed multiroom platform
inside speakers and soundbars from Phorus (PS1/PR1), Polk, Definitive
Technology, Klipsch (Stream), Onkyo/Pioneer, Paradigm, MartinLogan, SVS
(Prime Wireless), McIntosh, Anthem, Philips, and others. Several early brands
abandoned their products; as of July 2025 users report **Spotify Connect
permanently broken on Phorus-era/legacy-firmware devices** (Spotify community
thread, 2025-07-22) — i.e. the platform's cloud-side features are dying on
old hardware while the speakers still work on the LAN.

## Local control status — PARTIAL, rated hypothesis
**Confirmed local paths (in use today):**
- Play-Fi devices are **UPnP/DLNA media renderers** — open standard, no auth.
  `philippe44/AirConnect` streams AirPlay to Play-Fi speakers via UPnP
  (see AirConnect issue #178, 2019). Volume/play/pause via DLNA AVTransport
  works; this is the only *documented-by-use* local control path.
- Devices run an embedded web server (status/firmware-update pages).

**Proprietary app protocol (undocumented, greenfield opportunity):**
No public third-party client library exists for the Play-Fi control protocol
(verified via GitHub search 2026-08-07). Static triage of the official app
(see APK Provenance) shows:
- App↔speaker control runs over a **TLS socket** (`connectSSLSocket(
  ipAddressOfTheServerToConnectTo, PORT)`, `sendSSLCommand(...)`), with
  native libs `libphssl.so` / `libphsslsocket.so` (Phorus heritage; Java
  package namespace is still `com.phorus.playfi`).
- Visible command names: `VOLUME_CHANGE_REQUEST`, `METADATA_UPDATE_REQUEST`,
  `PAUSE_THE_AUDIO_REQUEST`, `SWITCH_INPUT_CHANNEL_REQUEST`,
  `TRACK_DATA_ACK`, `sendMCUDataPassThroughMessage`.
- Discovery: UDP broadcast "announce pulses"
  (`AnnouncementBroadcasterThread`); the app listens on **TCP 10108**
  (`ANNOUNCE_RESPONSE_LISTENER_PORT 10108`, falls back if busy) for
  `ANNOUNCEMENT_RESPONSE_FROM_GATEWAY` replies containing speaker IPs.
- The TLS control port was not pinned down in this triage (not a dex string;
  likely in the native socket lib or OBB assets). Next step: jadx the
  `connectSSLSocket` call sites, or one LAN capture of the app connecting to
  a speaker. TLS with what trust model (pinned cert? speaker self-signed?)
  is THE open question for whether a third-party client is feasible.

## APK Provenance
- **Package**: `com.dts.playfi` ("Play-Fi", DTS/Xperi)
- **Version**: 8.7.1.1491 (versionCode 8711491), XAPK from APKPure via apkeep
- **XAPK SHA-256**: `86592f5e82b4f6b379c2650bbbb22af23449de68cf269cd798a93bf338020a78`
- Path: `$REPO/workspace/apks/com.dts.playfi.xapk` (gitignored; 284 MB XAPK,
  main APK 78 MB + OBBs). Note: Google Play source failed (AAS token
  "Invalid payload"); APKPure worked on second attempt (first download
  truncated at exactly 125 MiB).

## Cloud steps required
None for the UPnP path. The app itself works without account sign-in for
basic local control, but the TLS protocol is un-RE'd so that path is not yet
usable by third parties. Initial Wi-Fi provisioning of legacy speakers used
the app or WPS.

## Spec work (priority order)
1. Document the UPnP/DLNA control surface (confirmed, immediate value).
2. jadx triage `connectSSLSocket`/`sendSSLCommand` call sites → port +
   framing + trust model (10–60 min).
3. One mitm/LAN capture of app→speaker session to confirm the above.

## Safety
LOW — audio only.

## Sources (accessed 2026-08-07)
- github.com/philippe44/AirConnect issue #178 (Play-Fi UPnP, 2019-08-18)
- community.spotify.com "No Phorus/DefinitiveTech/Play-Fi Playback"
  (2025-07-22) — legacy devices losing Spotify Connect
- APK static triage, this session (strings from classes.dex/classes2.dex
  and libphsslsocket.so)
