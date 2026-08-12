# Roku Local Remote — target spec

## Target metadata
- target_id: roku-local-remote
- app package_id(s): com.roku.remote (official Roku app)
- device class: streaming media player / smart TV
- transport(s): Wi-Fi LAN (HTTP on port 8060)
- local-only viability: **high** — Roku's External Control Protocol (ECP) is a fully local HTTP API with no authentication, no cloud dependency, and no encryption. The official mobile app itself uses ECP over the LAN.

## Known facts (public + observed)

### The protocol is fully documented
Roku publishes the [ECP specification openly](https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md). Every Roku device runs an HTTP server on **TCP port 8060** that accepts standard GET and POST requests. No SDK, pairing, tokens, or account are required — any device on the same LAN can send commands with `curl`.

### Discovery uses standard SSDP
Roku devices respond to [SSDP M-SEARCH](https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md#ssdp-discovery) on the standard UPnP multicast address (`239.255.255.250:1900`) with search target `roku:ecp`. They also send periodic `ssdp:alive` notifications (~every 20 minutes).

### No authentication whatsoever
ECP has no login, no tokens, no pairing flow, and no encryption. The only protection is a Host header check that verifies the request comes from a private/local IP (e.g., `192.168.x.x`). [Consumer Reports has flagged this as a security weakness](https://www.aftvnews.com/consumer-reports-says-rokus-unrestricted-remote-control-api-is-a-security-vulnerability/) compared to Apple TV and Fire TV.

### The official app uses the same protocol
The Roku mobile app communicates with Roku devices using ECP over the local Wi-Fi network — there is no proprietary or hidden protocol layer. This has been [confirmed by network traffic analysis](https://github.com/artemisaiev/roku-ecp-sniffer).

## Device discovery signals
- BLE: N/A (not used)
- Wi-Fi:
  - SSID patterns: N/A (joins existing network)
  - default gateway IPs: N/A
  - mDNS service types: N/A (uses SSDP instead)
  - UPnP / SSDP:
    - Search target: `roku:ecp`
    - Multicast address: `239.255.255.250:1900`
    - Response `Location` header: `http://<device-ip>:8060/`
    - Response `USN` header: `uuid:roku:ecp:<serial-number>`

### SSDP discovery request
```
M-SEARCH * HTTP/1.1
Host: 239.255.255.250:1900
Man: "ssdp:discover"
ST: roku:ecp
```

### SSDP discovery response
```
HTTP/1.1 200 OK
Cache-Control: max-age=300
ST: roku:ecp
Location: http://<device-ip>:8060/
USN: uuid:roku:ecp:<serial-number>
```

## Protocol specification (ECP — External Control Protocol)

### Query endpoints (HTTP GET)

| Endpoint | Description |
|---|---|
| `GET /query/device-info` | Device metadata: model, serial, software version, network info (XML) |
| `GET /query/apps` | List all installed channels/apps with app IDs (XML) |
| `GET /query/active-app` | Currently running app or screensaver (XML) |
| `GET /query/icon/{appID}` | Channel icon as binary image |
| `GET /query/media-player` | Media player state: play/pause, position, duration (XML) |
| `GET /query/tv-channels` | Available TV tuner channels (Roku TV only) |
| `GET /query/tv-active-channel` | Current tuned channel with signal info (Roku TV only) |

### Control endpoints (HTTP POST, empty body)

| Endpoint | Description |
|---|---|
| `POST /keypress/{key}` | Press and release a remote key |
| `POST /keydown/{key}` | Press and hold a key |
| `POST /keyup/{key}` | Release a held key |
| `POST /launch/{appID}[?params]` | Launch a channel with optional deep-link parameters |
| `POST /install/{appID}` | Open Channel Store page for a channel |
| `POST /input?{params}` | Send custom input/sensor data to the running app |
| `POST /search/browse?{params}` | Search for content (firmware 7.5+) |

### Keypress values

**Standard keys (all Roku devices):**
`Home`, `Rev` (rewind), `Fwd` (fast forward), `Play`, `Select`, `Left`, `Right`, `Down`, `Up`, `Back`, `InstantReplay`, `Info`, `Backspace`, `Search`, `Enter`, `FindRemote`

**Roku TV-only keys:**
`VolumeUp`, `VolumeDown`, `VolumeMute`, `PowerOn`, `PowerOff`, `ChannelUp`, `ChannelDown`, `InputTuner`, `InputHDMI1`, `InputHDMI2`, `InputHDMI3`, `InputHDMI4`, `InputAV1`

**Literal character input (for on-screen keyboards):**
Use the `Lit_` prefix followed by a URL-encoded character:
- `POST /keypress/Lit_a` → types "a"
- `POST /keypress/Lit_%20` → types a space
- Any UTF-8 character is supported via URL-encoding

### App launch with deep linking
```
POST /launch/{appID}?contentID=12345&mediaType=movie
```
Supported `mediaType` values: `series`, `season`, `episode`, `movie`, `short-form`, `special`, `live`

### Content search (firmware 7.5+)
```
POST /search/browse?keyword=breaking+bad&type=tv-show&season=1&launch=true
```
Parameters: `keyword`, `title`, `type`, `tmsid`, `season`, `show-unavailable`, `match-any`, `provider-id`, `provider`, `launch`

### Sensor/touch input
The `/input` endpoint accepts accelerometer, gyroscope, magnetometer, and multi-touch data for second-screen experiences:
- `acceleration.x/y/z` (m/s²)
- `rotation.x/y/z` (rad/s)
- `magnetic.x/y/z` (micro-Tesla)
- `touch.0.x`, `touch.0.y`, `touch.0.op` (operations: down, up, press, move, cancel)

## Threat model + guardrails
- Scope: only owned Roku devices on the user's own LAN.
- ECP has no authentication; anyone on the same network can control the device. A local-only remote app does not change the threat model — it matches what Roku already allows.
- Explicit non-goals: no cloud proxying, no remote-over-internet control, no credential harvesting.
- The user can disable ECP entirely via **Settings > System > Advanced System Settings > External Control > Disabled**.

## First experiments
1) SSDP discovery scan:
   ```bash
   # Quick scan for Roku devices on the LAN
   echo -e 'M-SEARCH * HTTP/1.1\r\nHost: 239.255.255.250:1900\r\nMan: "ssdp:discover"\r\nST: roku:ecp\r\n\r\n' | \
     socat - UDP4-DATAGRAM:239.255.255.250:1900,so-broadcast
   ```
2) Verify ECP access to a discovered device:
   ```bash
   curl http://<roku-ip>:8060/query/device-info
   curl http://<roku-ip>:8060/query/apps
   ```
3) Test keypress:
   ```bash
   curl -d '' http://<roku-ip>:8060/keypress/Home
   curl -d '' http://<roku-ip>:8060/keypress/Select
   ```
4) Static analysis of the official Roku APK is **not required** — the protocol is fully documented by Roku themselves. This is rare and ideal.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: **None.** No pairing, no auth. Confirmed by Roku docs.
- Session state machine: **Stateless.** Each HTTP request is independent.
- Commands: See endpoint tables above. All confirmed in official docs.
- Payload encoding: XML responses, empty POST bodies for commands.
- Timing constraints: None documented. Rapid-fire keypresses work fine.

## Control surface inventory (what the replacement app must support)

### Onboarding UX
- SSDP device discovery (auto-find Roku on LAN)
- Manual IP entry as fallback
- Display device name/model from `/query/device-info`

### Core controls (MVP)
- D-pad: Up, Down, Left, Right, Select
- Navigation: Home, Back
- Playback: Play/Pause, Rewind, Fast Forward
- Volume: Up, Down, Mute (Roku TV)
- Power: On, Off (Roku TV)
- Text input via `Lit_` keypresses (for search fields)

### Extended features
- App launcher (list from `/query/apps`, launch via `/launch/{appID}`)
- Media player status display (`/query/media-player`)
- Content search (`/search/browse`)
- App icons (`/query/icon/{appID}`)
- HDMI input switching (Roku TV)

### Error handling and recovery
- Re-discover if device becomes unreachable (SSDP re-scan)
- Timeout handling for HTTP requests
- Graceful handling when ECP is disabled on the device

## Local-only viability assessment

**Verdict: Fully viable — this is one of the easiest targets in the project.**

| Factor | Assessment |
|---|---|
| Protocol documentation | Fully public, official Roku developer docs |
| Authentication | None required |
| Cloud dependency | None for control path |
| Transport | Plain HTTP on port 8060 |
| Discovery | Standard SSDP |
| Complexity | Very low — stateless REST API |
| Legal risk | Very low — Roku publishes and encourages ECP use |
| Existing implementations | Many open source libraries in Python, JS, Rust, Kotlin |

Unlike most targets in this project, no reverse engineering is actually needed. Roku openly documents and encourages third-party ECP clients.

## Existing open source implementations

| Project | Language | Notes |
|---|---|---|
| [python-roku](https://github.com/jcarbaugh/python-roku) | Python | Mature, widely used |
| [python-rokuecp](https://github.com/ctalkington/python-rokuecp) | Python (async) | Modern async implementation |
| [roku-cli](https://github.com/ncmiller/roku-cli) | Python | CLI remote control |
| [rokujs](https://github.com/gamontal/rokujs) | Node.js | JavaScript implementation |
| [RoMote](https://github.com/wseemann/RoMote) | Android/Kotlin | Full Android remote app |
| [roku-ecp-rs](https://github.com/Hermitter/roku-ecp-rs) | Rust | Rust library |
| [Home Assistant](https://www.home-assistant.io/integrations/roku/) | Python | Full HA integration |

## References

### Official documentation
- [Roku External Control API (ECP)](https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md) — current official spec
- [Roku ECP archived docs](https://sdkdocs-archive.roku.com/External-Control-API_1611563.html) — older SDK documentation mirror

### Open source implementations
- [python-roku](https://github.com/jcarbaugh/python-roku) — mature Python library
- [python-rokuecp](https://github.com/ctalkington/python-rokuecp) — modern async Python library
- [roku-cli](https://github.com/ncmiller/roku-cli) — Python CLI remote control
- [rokujs](https://github.com/gamontal/rokujs) — Node.js library
- [RoMote](https://github.com/wseemann/RoMote) — full Android/Kotlin remote app
- [roku-ecp-rs](https://github.com/Hermitter/roku-ecp-rs) — Rust library ([docs.rs](https://docs.rs/roku-ecp/latest/roku_ecp/))
- [Roku::ECP](https://metacpan.org/release/ARENSB/Roku-ECP-1.0.0/view/lib/Roku/ECP.pm) — Perl module
- [Home Assistant Roku integration](https://www.home-assistant.io/integrations/roku/) — full HA integration

### Security and analysis
- [Consumer Reports on Roku's unrestricted ECP API](https://www.aftvnews.com/consumer-reports-says-rokus-unrestricted-remote-control-api-is-a-security-vulnerability/) — security concerns
- [Abusing Roku APIs](https://github.com/RoseSecurity/Abusing-Roku-APIs) — Bash/curl examples of ECP usage
- [roku-ecp-sniffer](https://github.com/artemisaiev/roku-ecp-sniffer) — captures ECP traffic by impersonating a Roku device

### Community
- [Discovering Roku devices using SSDP](https://medium.com/@amitdogra70512/discovering-nearby-roku-devices-using-ssdp-a7a45c4a0637) — SSDP discovery walkthrough
- [Roku Community: ECP 403 Forbidden](https://community.roku.com/t5/Roku-Developer-Program/External-Control-API-suddenly-returns-403-Forbidden/td-p/499344) — Host header validation behavior
