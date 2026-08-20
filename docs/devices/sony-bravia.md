# Sony Bravia TVs — IRCC-IP and REST API

> **Status**: Documented from Sony's official references and pybravia/Home Assistant; not replayed against hardware here
> **Protocol**: WiFi (SSDP + HTTP on port 80; SOAP and JSON-RPC-style POSTs)
> **Manufacturer**: Sony
> **Manufacturer Status**: Active

## Overview

Bravia TVs from 2013 onward (including the FW-BZ professional displays)
expose two local control surfaces on port 80:

- **IRCC-IP** — SOAP POSTs to `/sony/IRCC`, one base64 remote-key code per
  call. The wire sibling of the infrared remote: every button press is an
  `X_SendIRCC` action carrying an `IRCCCode`.
- **The Bravia REST API** ("Scalar Web API") — POSTs to `/sony/<service>`
  (`system`, `avContent`, `appControl`, `audio`, `guide`, ...) with a
  JSON-RPC-flavoured body `{"method", "params": [...], "id", "version"}`.
  Covers identity, power, volume, input switching, app launching and
  content listing.

Both surfaces are **off until the user enables IP control on the TV**, and
both require authentication once enabled.

> **Transport gap**: every request here is a POST with a **body** (SOAP
> envelope or JSON document) plus an **auth header** (`X-Auth-PSK` or the
> pairing cookie). The reference app today sends GET/POST with an empty body
> and no per-device headers. A client must implement *SOAP with arguments
> plus a per-device auth header* (the IRCC keys) and *JSON-body POSTs with
> the same header* (the REST surface) — neither is yet supported by the
> reference app. The machine-readable spec therefore declares the IRCC keys
> as `transport: "soap"` commands and catalogues the REST methods in
> `http_endpoints` only.

## Discovery

SSDP M-SEARCH to `239.255.255.250:1900` with either search target:

- `urn:schemas-sony-com:service:ScalarWebAPI:1` — the REST API. `LOCATION`
  points at `/sony/webapi/ssdp/dd.xml`, whose
  `X_ScalarWebAPI_ServiceList` names every REST service and its base URL
  (resolve ports from here rather than assuming 80).
- `urn:dial-multiscreen-org:service:dial:1` — DIAL second-screen discovery
  (YouTube/Netflix pairing). The response's `Application-URL` header is the
  DIAL REST base; app icons are served under `/DIAL/icon/`. DIAL is
  unauthenticated but offers no power/key/volume control.

Identity (serial, MAC, model, user name) is **not** in either descriptor —
fetch it from the REST API once authenticated:

```
POST /sony/system
{"method": "getSystemInformation", "params": [], "id": 1, "version": "1.0"}
```

→ `serial` (primary key), `macAddr` (secondary), `name` (display), `model`.

## Authentication

Enable on the TV first: *Settings > Network & Internet > Remote device
settings > Control remotely = On* (older models: *Settings > Network > Home
Network Setup > IP Control*). Then one of:

- **Pre-shared key** (recommended by Home Assistant): set *Remote device
  settings > IP control > Pre-Shared Key*; the client sends
  `X-Auth-PSK: <key>` on every request, SOAP and REST alike. No handshake,
  no expiry.
- **PIN pairing**: POST `actRegister` to `/sony/accessControl` with HTTP
  Basic auth (empty username, password `0000`) to make the TV show a PIN,
  then repeat with the shown PIN as the Basic-auth password. Success
  returns `Set-Cookie: auth=...`; send that cookie on every later request.
  Note the TV's Set-Cookie spelling is not RFC-compliant — strict cookie
  jars silently drop it (pybravia issue #1). A TV that refuses to show a
  new PIN still has the old client registered: remove it via *Settings >
  Network > Remote device settings > Deregister remote device*.

Unauthenticated calls on a locked TV answer 401/403; a TV in standby
answers control calls with the error string `"not power-on"`.

## IRCC-IP (remote keys)

```
POST /sony/IRCC
Content-Type: text/xml; charset=UTF-8
SOAPACTION: "urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"
X-Auth-PSK: <key>

<s:Envelope ...><s:Body>
  <u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">
    <IRCCCode>AAAAAQAAAAEAAABgAw==</IRCCCode>   <!-- Home -->
  </u:X_SendIRCC></s:Body></s:Envelope>
```

Success is a bare 200; there is no per-key feedback. Quirks worth copying
from pybravia rather than rediscovering:

- **Case**: `/sony/IRCC` on most models, `/sony/ircc` on some — the wrong
  case answers 404; probe and swap.
- **Idle drop**: after ~13 idle minutes the first command is silently
  ignored; send an empty-code wake-up first.
- **Code authority**: the TV's own `getRemoteControllerInfo` REST call
  returns its exact key table and wins over any static list. Sony's
  published pro-display table and the widely-copied community table
  disagree on some keys (Left/Right, Prev).

The spec's `commands` block carries the full published table — power,
navigation, digits 0-9, transport, volume/channel, colour keys, HDMI 1-4 —
plus consumer-set codes from pybravia/community sources (`PowerOn`,
`PowerOff`, `Exit`, `Rewind`, `Forward`, `EPG`), each labelled by source.

## REST API

| Service | Method | Purpose |
|---|---|---|
| `/sony/guide` | `getSupportedApiInfo` | Per-device inventory of services/methods/versions (authLevel none — call first) |
| `/sony/system` | `getSystemInformation` | Identity: model, serial, macAddr, name |
| `/sony/system` | `getPowerStatus` / `setPowerStatus` | Power state read/write |
| `/sony/system` | `getRemoteControllerInfo` | This model's IRCC key table |
| `/sony/system` | `requestReboot` | Recovery when the REST service freezes |
| `/sony/audio` | `getVolumeInformation` | Per-target volume/mute (0-100) |
| `/sony/audio` | `setAudioVolume` / `setAudioMute` | Volume as `"N"`/`"+N"`/`"-N"`; mute needs read-then-invert |
| `/sony/avContent` | `getPlayingContentInfo` | What's on (input or tuner programme; blind inside Android apps) |
| `/sony/avContent` | `getCurrentExternalInputsStatus` | Input list with `extInput:hdmi?port=N` URIs |
| `/sony/avContent` | `setPlayContent` | Switch input/channel by URI — Bravia's input switching |
| `/sony/appControl` | `getApplicationList` | Installed apps: `title`, `uri`, `icon` |
| `/sony/appControl` | `setActiveApp` | Launch an app by its URI |
| `/sony/appControl` | `setTextForm` | Type into the on-screen keyboard |
| `/sony/accessControl` | `actRegister` | PIN pairing (see Authentication) |

**Power on** (from network standby only): WoL magic packet (needs the TV's
Remote Start setting), `setPowerStatus {"status": true}`, or the IRCC
`PowerOn` code — pybravia tries all three.

**Known instability**: the REST surface is served by the TV's WebApiCore
system app, which freezes on long uptimes. Recovery is a full TV reboot
(hold Power on the remote > Restart, or `requestReboot`) or clearing
WebApiCore's data under *Settings > Apps*.

## Control surface in the spec

`entities` declares the remote as `button` entities in remote-layout order
(power, navigation, digits, transport, volume/channel, colour keys, HDMI
inputs), each bound to one IRCC `soap` command. Three `sensor` entities
(Power Status, Now Playing, Volume) bind REST reads via
`state_endpoint`/`state_command`, and an `Application` select binds
`getApplicationList` — the sensors and select are declared with their
transport gap in their notes and become live once the app can send JSON
bodies with auth headers.

A stateful **Power** `switch` entity binds `turn_on`/`turn_off` to the
discrete IRCC codes and `toggle` to the one key every set carries, with the
`getPowerStatus` read as its state
([Spec Evolution P13](../contributing/spec-evolution.md#p13)) — the standby
error string `not power-on` on any other call is that reading saying
"standby", not a failure.

Machine-readable spec: `device-specs/devices/sony-bravia.yaml`

## References

- [Sony — IRCC-IP overview](https://pro-bravia.sony.net/develop/integrate/ircc-ip/overview/index.html)
- [Sony — IRCC Codes](https://pro-bravia.sony.net/develop/integrate/ircc-ip/ircc-codes/)
- [Sony — BRAVIA REST API reference](https://pro-bravia.sony.net/remote-display-control/rest-api/reference/)
- [pybravia (Home Assistant's client)](https://github.com/Drafteed/pybravia)
- [Home Assistant Sony Bravia TV integration](https://www.home-assistant.io/integrations/braviatv/)
- [kalleth's Sony Bravia HTTP API notes](https://gist.github.com/kalleth/e10e8f3b8b7cb1bac21463b0073a65fb)
- [DIAL protocol specification](https://www.dial-multiscreen.org/dial/protocol-specification)
- [Community IRCC code table (consumer keys)](https://github.com/cmos486/Bravia-REST-API/blob/main/COMMANDS.md)
