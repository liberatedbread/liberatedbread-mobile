# Linkplay WiMu modules (AudioCast M5, iEast, MUZO Cobblestone, August, Arylic…) — Research Notes

## What it is
Linkplay Technology (Shenzhen) Wi-Fi audio modules (A28/A31/A98, "WiMu"
firmware) are the white-label engine inside dozens of network audio adapters
and speakers: AudioCast M5, iEast AudioCast/Stream Pro, MUZO Cobblestone,
August WS150/WS300, Dayton Audio WBA31, Sonoé, Andoer, and — via heavily
extended derivatives — WiiM and Arylic (both still active brands). Many of the
small brands are defunct or their apps abandoned, which is exactly where the
local API is the rescue.

## Local API — fully documented, no auth
HTTP GET API on port 80:

    http://<ip>/httpapi.asp?command=<cmd>

Canonical command transcription:
[AndersFluur/LinkPlayApi api.md](https://github.com/AndersFluur/LinkPlayApi/blob/master/api.md)
(translated from the leaked Linkplay PDF). Arylic (a Linkplay-affiliated
active brand) publishes essentially the same API officially at
[developer.arylic.com/httpapi](https://developer.arylic.com/httpapi/).

Key commands (response `OK` or JSON):
- `getStatus` — firmware, MAC, IPs, UUID, device name, enabled stream bitfield
- `getPlayerStatus` — mode (1 AirPlay, 2 DLNA, 10 LinkPlay app, 40 line-in,
  41 BT, 99 slave), play state, position, volume, mute; title/artist/album
  hex-encoded
- `setPlayerCmd:play:<uri>` / `pause` / `onepause` / `resume` / `stop` /
  `prev` / `next` / `seek:<ms>` / `vol:<0-100>` / `mute:<0|1>` /
  `loopmode:<n>` / `equalizer:<0-4>`
- `setPlayerCmd:switchmode:line-in|optical|UDISK|wifi` — input select
- Multiroom: `multiroom:getSlaveList`, `multiroom:SlaveJoin` family,
  `multiroom:SlaveKickout:<ip>`, `multiroom:SlaveVolume:<ip>:<vol>`,
  `multiroom:Ungroup`
- Config: `setDeviceName:<hex>`, `wlanConnectApEx:...`, `setShutdown:<sec>`,
  `reboot`, `restoreToDefault`

## Root shell (verified in the published doc)
- Firmware ~2015 and earlier: open telnet, `admin`/`admin`, root.
- Modern firmware: one unauthenticated HTTP call enables telnet until reboot:
  `http://<ip>/httpapi.asp?command=507269765368656C6C:5f7769696d75645f`
  (hex for `PrivShell:_wiimud_`), then telnet port 22, `admin`/`admin` → root.
  This makes firmware dumping/modding trivial and is a serious LAN security
  note for any spec.

## Discovery
Devices advertise AirPlay (mDNS `_raop._tcp`) and DLNA/UPnP (SSDP); app-side
discovery also uses UDP broadcast. No auth anywhere on the HTTP API.

## Community implementations (confirmed)
- Music Assistant has a Linkplay/WiiM-family player provider.
- Home Assistant custom integrations (`linkplay`), plus WiiM's own HA
  support built on the extended API.
- The WiiM derivative API (same `httpapi.asp` shape) is documented at
  community level and by Arylic officially.

## APK
Not fetched — protocol is already documented above the app level. Companion
apps (AudioCast/MUZO Player/`com.linkplay…` family) are only needed for
first-time Wi-Fi provisioning, and even that is bypassable: modules expose an
onboarding AP and `wlanConnectApEx` can join them to a LAN over HTTP.

## Cloud steps required
None for control. Streaming-service logins (Spotify Connect etc.) live inside
the apps/firmware but are not needed for local `play:<uri>` / DLNA / AirPlay /
line-in use.

## Security/safety
LOW (audio), but flag in any spec: unauthenticated full control + root-telnet
backdoor + plaintext Wi-Fi PSK returned by `getNetwork`/`getStatus` on some
firmware. Recommend isolation VLAN.

## Sources (accessed 2026-08-07)
- github.com/AndersFluur/LinkPlayApi (api.md)
- developer.arylic.com/httpapi (vendor-published)
