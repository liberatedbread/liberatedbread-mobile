# LG webOS TV Second Screen Protocol (SSAP)

> **Status**: Documented from open-source clients — not replayed against hardware here
> **Protocol**: WiFi (SSDP + WebSocket JSON on ports 3000/3001)
> **Manufacturer**: LG Electronics
> **Manufacturer Status**: Active

## Overview

Every LG smart TV since webOS 1.0 (2014) exposes the same local control
protocol: a WebSocket on port 3000 (`wss` on 3001), a JSON register/pairing
handshake that the user must accept on the TV screen, and SSAP URIs
(`ssap://audio/volumeUp`, `ssap://system/turnOff`, …) for every command
afterwards. LG never published a wire-format document; the protocol is known
through LG's own open-source Connect SDK and the community clients
(aiowebostv, bscpylgtv, openHAB's lgwebos binding).

**Transport gap**: control needs a *WebSocket transport with client-key
pairing — not yet supported by the reference app*, whose command transports
are HTTP and SOAP. The spec therefore records each command's wire spelling
(`action`) and the frame format (`webos_common`) without declaring an
executable `transport:`; nothing in it should be turned into an HTTP request.

## Discovery

SSDP M-SEARCH with:

```
ST: urn:lge-com:service:webos-second-screen:1
```

The response `LOCATION` is a standard UPnP device-description XML (on the
TV's own UPnP port, not 3000) carrying `UDN`, `serialNumber`, `friendlyName`
and `modelName`. Use `UDN` then `serialNumber` for identity, `friendlyName`
for display. The TV sends `ssdp:byebye` for this search target when it powers
off, which doubles as an availability signal. There is no mDNS advertisement
for the second-screen service.

## Pairing

Prerequisite on the TV: **Settings > Network > LG Connect Apps = On** (older
firmware: Settings > General > Mobile App). Then, per connection:

1. Open `ws://<ip>:3000`; on refusal or a rejected upgrade, fall back to
   `wss://<ip>:3001` (self-signed certificate — clients disable verification;
   late firmware enforces wss).
2. Send `{"id":"hello","type":"hello","payload":{}}`, then a pre-registration
   `ssap://system/getSystemInfo` request (newer firmware expects it first).
3. Send the `register` frame (`pairingType: "PROMPT"`, pairing manifest with
   the permissions list and the boilerplate `signed` block every client
   copies from Connect SDK — the exact bytes are in aiowebostv's
   `handshake.py`).
4. First time, the TV shows an **accept prompt on screen**; on acceptance a
   second message of type `registered` delivers the `client-key` (32 hex
   chars). Store it: it is included in the register payload on every later
   connection and is bearer credentials until revoked on the TV.

## Command channel

Commands are JSON text frames on the paired socket:

```json
{"id": 12, "type": "request", "uri": "ssap://audio/volumeUp", "payload": {}}
```

`type: "subscribe"` turns any query into a push stream on the same id.
Success answers `type: "response"` with `payload.returnValue: true`; failure
answers `type: "error"` — `404 no such service or method` means the URI is
absent on that firmware, `401 insufficient permissions` means it is outside
the pairing manifest.

### SSAP URIs (reported, from bscpylgtv / aiowebostv)

| Group | URI | Notes |
|---|---|---|
| Power | `ssap://system/turnOff` | Standby; socket drops with the TV |
| Screen | `ssap://com.webos.service.tvpower/power/turnOffScreen` / `turnOnScreen` | webOS 4+; older sets used the removed `com.webos.service.tv.power/*` pair |
| Volume | `ssap://audio/volumeUp` / `volumeDown` / `setVolume` / `setMute` / `getVolume` / `getStatus` | Absolute set works on internal speakers only |
| Channel | `ssap://tv/channelUp` / `channelDown` / `openChannel` / `getChannelList` / `getCurrentChannel` | Tuner input |
| Input | `ssap://tv/getExternalInputList` / `switchInput` | Inputs are apps too (`com.webos.app.hdmi1`…) |
| Apps | `ssap://com.webos.applicationManager/listLaunchPoints` / `listApps` / `getForegroundAppInfo`; `ssap://system.launcher/launch` / `close` | `launch` takes `{id}`, optional `params`, `contentId` deep link |
| Media | `ssap://media.controls/play` / `pause` / `stop` / `rewind` / `fastForward` | Acts on the foreground app |
| Notify | `ssap://system.notifications/createToast` | Icon payload ignored on newer firmware |
| Text | `ssap://com.webos.service.ime/insertText` / `sendEnterKey` / `deleteCharacters` | On-screen keyboard fields |
| System | `ssap://system/getSystemInfo`, `ssap://api/getServiceList`, `ssap://com.webos.service.update/getCurrentSWInformation` | Identity/version reads |

Removed by firmware (kept for the record): `ssap://system/turnOn`, the 3D
pair, the webOS <4 screen-power pair.

## Remote buttons (pointer input socket)

Button presses are **not** SSAP requests. Request
`ssap://com.webos.service.networkinput/getPointerInputSocket`, open the
second WebSocket its `socketPath` returns, and send plain-text frames:

```
type:button
name:HOME

```

(key:value lines, blank-line terminated; also `type:move`/`click`/`scroll`
for the Magic Remote pointer). Known names: LEFT, RIGHT, UP, DOWN, ENTER (the
OK button), BACK, EXIT, HOME, INFO, digits 0-9, RED/GREEN/YELLOW/BLUE, PLAY,
PAUSE, STOP. On the earliest webOS 1.x sets (2014–2015) the socket is
accepted but inert — a firmware limitation; only SSAP commands work there.

## Power on

There is no network power-on (`ssap://system/turnOn` was removed). Wake is
**Wake-on-LAN**, gated on the TV: Settings > General > Mobile TV On > Turn On
Via WiFi (2017+ models), or Settings > Support > IP control settings > Wake
on LAN (2025+ models); it works most reliably over Ethernet and requires the
TV's MAC, captured while it is on.

Power in the spec is therefore one-way: a stateful **Power** `switch` entity
binds only `turn_off: power_off`
([Spec Evolution P13](../contributing/spec-evolution.md#p13)) — no `turn_on`
to bind, no power state to read; an unreachable socket is the closest thing
to "off" webOS offers.

## Tools Used

- [x] Source reading: LG Connect SDK, aiowebostv, bscpylgtv, openHAB lgwebos
- [ ] Live capture against hardware (none available to this project)

## References

- [Home Assistant — LG webOS TV integration](https://www.home-assistant.io/integrations/webostv/)
- [aiowebostv](https://github.com/home-assistant-libs/aiowebostv) (incl. [`handshake.py`](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/handshake.py))
- [bscpylgtv](https://github.com/chros73/bscpylgtv) (incl. [`endpoints.py`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/endpoints.py))
- [Connect SDK — LG's own open-source client](https://github.com/ConnectSDK/Connect-SDK-Android)
- [openHAB — LG webOS binding](https://www.openhab.org/addons/bindings/lgwebos/)
- [pylgtv — the original Python client (archived)](https://github.com/TheRealLink/pylgtv)

Machine-readable spec: `device-specs/devices/lg-webos.yaml`
