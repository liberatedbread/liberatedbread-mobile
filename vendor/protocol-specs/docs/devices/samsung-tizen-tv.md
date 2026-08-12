# Samsung Tizen Smart TV (2016+)

> **Status**: Complete local protocol documented from open-source clients; nothing replayed against hardware
> **Protocol**: WiFi (SSDP discovery; WebSocket control on 8001/8002 + REST under `/api/v2/`)
> **Manufacturer**: Samsung Electronics
> **Manufacturer Status**: Active

## Overview

Samsung Smart TVs from 2016 on run Tizen and expose an unpublished but well
trodden local control API. The control channel is a **WebSocket** to
`/api/v2/channels/samsung.remote.control` on port **8001** (plain `ws`) or
**8002** (`wss`, self-signed certificate). Keys are injected as
`ms.remote.control` JSON frames; a small unauthenticated REST API under
`/api/v2/` covers device info and app status/launch. The reference
implementation is [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api),
the library Home Assistant's
[Samsung Smart TV integration](https://www.home-assistant.io/integrations/samsungtv/)
wraps. Samsung publishes none of this; every detail here is reconstructed
from those clients and marked `reported`, never `confirmed`.

## Discovery

SSDP M-SEARCH for `urn:samsung.com:device:RemoteControlReceiver:1` (also
answered: `urn:samsung.com:service:MainTVAgent2:1`, and
`urn:schemas-upnp-org:service:RenderingControl:1` with a Samsung manufacturer
string — Home Assistant uses all three). The `LOCATION` fetches a UPnP
description whose `friendlyName` (`[TV] Samsung 6 Series (55)`), `modelName`
and `UDN` identify the set. Note the description port is *not* the control
port: control is always 8001/8002 on the same host. 2018+ sets also advertise
`_airplay._tcp`, which says "speaks AirPlay", not "is a Samsung TV".

For stable identity beyond the UDN, fetch `GET http://<ip>:8001/api/v2/` —
the JSON document carries `device.duid`, `device.wifiMac` (the Wake-on-LAN
target), `device.modelName`, and network details.

## Pairing (authentication)

No PIN, no shared secret — authorization is the user pressing **Allow** on
the TV:

1. Client opens `ws(s)://<ip>:<port>/api/v2/channels/samsung.remote.control?name=<base64(client-name)>[&token=<token>]`.
2. First connection from an unknown name raises an Allow/Deny dialog on the
   TV. Deny or timeout arrives as an `ms.channel.unauthorized` event —
   surface that as "approve on the TV", not as a network failure.
3. On approval the TV sends `ms.channel.connect` whose `data.token` is a
   reusable auth token. Store it and pass it as the `token` query parameter
   on every later connection (the token is appended on the TLS port 8002;
   port 8001 authenticates by client name alone).
4. Newer TVs default to prompting on **every** connection. Fix on the TV:
   *General > External Device Manager > Device Connection Manager > Access
   Notification → First Time Only*; stale approvals are revoked in the
   *Device List* next door.

Two environmental traps, both documented by samsungtvws and Home Assistant:
the TV **refuses WebSocket connections from a different subnet/VLAN**, and
the client `name` in the URL *is* the identity — rename the client and the
TV treats it as a stranger.

## Command channel

One JSON text frame per key:

```json
{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_HOME","Option":"false","TypeOfRemote":"SendRemoteKey"}}
```

`Cmd` is `Click` (press+release, the normal case), `Press` or `Release` — a
held key is Press, pause, Release. `DataOfCmd` is a `KEY_*` name; the full
vocabulary (unofficial, varies by model) is in
[samsungtvws COMMANDS.md](https://github.com/xchwarze/samsung-tv-ws-api/blob/master/COMMANDS.md)
and the [homebridge-samsung-tizen command page](https://tavicu.github.io/homebridge-samsung-tizen/extra/commands.html).
Clients throttle repeats (~1 s inter-key delay by default). Text entry is
`SendInputString` with the base64 text in `Cmd`; a cursor device
(`ProcessMouseDevice`) exists on some models.

Generational trap: pre-2016 `KEY_POWERON`/`KEY_POWEROFF` collapse to a
single `KEY_POWER` toggle on 2016+ sets. And no network command powers a
standby TV **on** — the network stack is down; power-on is Wake-on-LAN to
`device.wifiMac`.

## Apps

- **List**: WebSocket only — `ms.channel.emit` with
  `{"event":"ed.installedApp.get","to":"host"}`, answered by an
  `ed.installedApp` event (and *not* answered at all on some models). There
  is no REST app list.
- **Launch**: REST `POST /api/v2/applications/{app_id}` (empty body,
  unauthenticated), or over the socket `ed.apps.launch` with
  `{"action_type":"DEEP_LINK"|"NATIVE_LAUNCH","appId":...,"metaTag":...}` —
  opening a URL is `org.tizen.browser` with NATIVE_LAUNCH and the URL as
  metaTag.
- **Status / close / install**: `GET` / `DELETE` / `PUT` on the same REST
  path.

## Transport gap

**WebSocket transport with token auth — not yet supported by the reference
app.** The app's command transports are `http` and `soap`; every remote-key
command in the spec therefore declares no `transport` and inherits
`device.transport: "websocket"`, which is the recorded gap, not an
oversight. A consumer that wants the remote must implement: RFC 6455
(including TLS against a self-signed certificate on 8002), the
`ms.channel.connect` / `ms.channel.unauthorized` handshake, token capture
and reuse, and session keepalive. The one command sendable today is
`launch_app` (REST POST). The legacy protocol below needs a third transport
(raw TCP 55000), also unimplemented.

## Legacy variant: pre-2016 (Orsay) TVs, TCP 55000

An Orsay-era Samsung TV answers the same SSDP family but has nothing on
8001/8002; its control is raw TCP on port **55000** (reference:
[samsungctl](https://github.com/Ape/samsungctl) `remote_legacy.py`):

- All strings are base64-encoded, then length-prefixed as
  `[len][0x00][bytes]`.
- Handshake: outer header `00 00 00`, then the controller-string payload
  `64 00` + serialized description + serialized client id + serialized
  client name (samsungctl defaults: `"PC"`, `""`, `"samsungctl"`; other
  clients famously send `iphone..iapp.samsung`).
- Key press: outer header `00 00 00`, inner payload `00 00 00` + serialized
  base64 `KEY_*`.
- Replies: 3-byte header (bytes 1–2 = little-endian TV-name length), the TV
  name, then a 2-byte length and body — `64 00 01 00` access granted,
  `64 00 00 00` denied, leading `0A` the Allow/Deny prompt is on screen,
  leading `65` cancelled, `00 00 00 00` key accepted.

Between the two generations sits a third: H-series (2014) and part of
J-series (2015) speak WebSocket on 8001 wrapped in an AES-encrypted pairing
exchange (samsungtvws's `encrypted` extra). Noted, **not** specified here —
an open research item.

## Factory reset / rejoin

Factory reset is *Settings > General > Reset* (some years: *Settings >
Support > Self Diagnosis > Reset*), PIN default `0000`; it clears network,
accounts, apps, and the approved-client list — every pairing token dies with
it. Moving routers needs no reset: *Settings > General > Network > Network
Settings* re-runs just the network step.

Machine-readable spec: `device-specs/devices/samsung-tizen-tv.yaml`
