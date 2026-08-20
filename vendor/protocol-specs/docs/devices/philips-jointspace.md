# Philips jointSPACE TV API

> **Status**: Complete protocol reconstruction from published clients and docs; nothing probed against live hardware (this project owns no Philips TV)
> **Protocol**: WiFi (mDNS + HTTP/HTTPS JSON on ports 1925/1926)
> **Manufacturer**: Philips / TP Vision
> **Manufacturer Status**: Active (current TP Vision Android/Saphi TVs still ship the API; 2k9-2k13 jointSPACE models are long out of support)

## Overview

Philips smart TVs expose a local REST-style JSON API whose URL prefix is the
API major version: `/1` on the original 2009-2013 jointSPACE models, `/5` on
2014-2015 non-Android sets, `/6` on Android (2014+) and Saphi/Linux TVs.
Philips published the v1 documentation (and shipped it on the TV itself at
`http://<ip>:1925/1/doc/`); v5/v6, the pairing flow and the secured transport
were never officially documented and were recovered by suborb (2016 pairing),
pylips (MITM of the official remote app) and haphilipsjs (the library behind
Home Assistant's Philips TV integration).

## Discovery

The TVs announce themselves over mDNS with two service types — the same two
Home Assistant's `philips_js` manifest listens for:

| Service type | Port | Meaning |
|---|---|---|
| `_philipstv_rpc._tcp.local.` | 1925 | Plain HTTP API, no auth |
| `_philipstv_s_rpc._tcp.local.` | 1926 | Secured API: HTTPS + digest auth |

mDNS yields an address and a display name only. Identification is completed
with the unversioned probe — try `http://<ip>:1925/system`, then
`https://<ip>:1926/system` — whose answer carries `api_version.Major` (pick
your URL prefix from it), the TV name, and `featuring.systemfeatures` with
`secured_transport` and `pairing_type` (pick your auth regime from those).
Stable identity is `serialnumber_encrypted` / `deviceid_encrypted` in the
same document: AES-128-CBC, key = first 16 bytes of the base64-decoded shared
key (below), IV = first 16 bytes of the decoded payload, PKCS7 padding.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — on-TV first-time installation wizard |
| Method | `device_ui` |
| Passphrase protection | not_applicable (typed on the TV itself) |
| Confidence | medium (public sources; not run by this project) |

On 2k9-2k11 models only, the JSON API needs a one-time activation: while
watching TV, type `5646877223` on the remote ("jointspace" in multitap digit
entry), per the jointSPACE project page. 2014+ models have the API always on.

**Factory reset**: Settings > General settings > Factory settings (or
"Reinstall TV" on Android models) — clears channel lists, network settings
and paired-client credentials, returns to the installation wizard.
**Rejoining a new network**: in place from the network settings menu; a
factory reset is never needed for a router change, and pairing credentials
survive it.

## Authentication

Two regimes, and the TV itself says which applies:

- **Open (pre-2016, v1/v5 and early Android)**: plain HTTP on 1925, no
  credentials at all. Anything on the LAN can drive the TV.
- **`digest_auth_pairing` (2016+ Android, v6)**: HTTPS on 1926 with a
  self-signed certificate, and every request — GETs included — answers 401
  without HTTP digest auth.

Pairing (once per client; wire paths are `/6/pair/request` and
`/6/pair/grant` — often miswritten "pairing/..." in secondary docs):

1. `POST /6/pair/request` (no auth) with a device descriptor
   (`{"device": {"id": <client-chosen id>, "device_name": ..., "device_os":
   ..., "type": "native", "app_id": ..., "app_name": ...}}` plus requested
   scope). The TV answers `{"timestamp", "auth_key", "timeout"}` and shows a
   4-digit PIN on screen.
2. The user reads the PIN off the TV; the client POSTs `/6/pair/grant` with
   digest auth (username = device id, password = `auth_key`) and body
   `{"auth": {"auth_AppId": "1", "pin": <PIN>, "auth_timestamp": <timestamp>,
   "auth_signature": base64(HMAC-SHA1(shared_key, str(timestamp) + pin))},
   "device": {...}}`. `{"error_id": "SUCCESS"}` ends the exchange.
3. All subsequent requests use digest auth with device id / `auth_key`.
   Credentials survive until the TV is reset or unpaired.

The HMAC shared key is a constant shipped in every published client
(`ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==`,
base64). One divergence in the sources: suborb's 2016 original base64-encoded
the HMAC's *hex* digest; haphilipsjs base64-encodes the raw digest and is the
maintained form Home Assistant pairs with today.

## Local API

All paths are prefixed `/<api_version>/` (1, 5 or 6). POSTs carry a JSON
object as the entire body.

| Method | Path | Description |
|---|---|---|
| GET | `/system` (unversioned) | Probe: API version, name, encrypted identity, `secured_transport`/`pairing_type` |
| GET | `/{v}/system` | Same document, versioned; fields also GETtable individually (v1) |
| POST | `/{v}/input/key` | Send one remote key: `{"key": "Home"}`; also `{"unicode": "x"}` for text entry |
| GET/POST | `/{v}/audio/volume` | Volume/mute state; set with `{"current": n, "muted": b}` (device scale, not percent) |
| GET/POST | `/{v}/powerstate` | Power state; set `{"powerstate": "Standby"}` (v6, not all firmwares) |
| GET | `/{v}/screenstate` | Panel on/off (v5+) |
| GET | `/{v}/channeldb/tv` | Channel-list index: list `all` plus favourite lists (v5+) |
| GET | `/{v}/channeldb/tv/channelLists/{id}` | Channels of one list; `ccid` is the tunable value |
| GET/POST | `/{v}/activities/tv` | Current channel; tune with `{"channelList": {"id": "all"}, "channel": {"ccid": n}}` (v5+; v1 spells it `/1/channels/current`) |
| GET | `/{v}/applications` | Launchable apps with Android intents (v6 Android) |
| GET | `/{v}/activities/current` | Foreground activity intent (v6 Android) |
| POST | `/{v}/activities/launch` | Launch an app by replaying its intent; a `SELECTURI` intent also switches HDMI inputs where honoured |
| GET/POST | `/{v}/sources` + `/sources/current` | Input list and switching — **v1 only**, removed in v5/v6 (use the Source key or a SELECTURI intent) |
| POST | `/{v}/pair/request`, `/{v}/pair/grant` | Pairing (v6 secured models) |
| POST | `/{v}/notifychange` | Long-poll state push: POST last-known state, TV answers with what changed (v6, models advertising `notifyChange`) |
| GET/POST | `/{v}/ambilight/mode`, `/{v}/ambilight/power` | Ambilight control mode and on/off |

### Remote key vocabulary

`POST /{v}/input/key` takes one of (union of the official v1 reference,
pylips' v6-tested list and Home Assistant's remote entity): `Standby`,
`PowerOn`, `PowerOff`, `CursorUp/Down/Left/Right`, `Confirm`, `Back`, `Exit`,
`Home`, `Options`, `Adjust`, `Find`, `WatchTV`, `Source`, `List`, `Viewmode`,
`TvGuide`, `Info`, `Subtitle`, `Teletext`, `ClosedCaption`,
`Red/Green/Yellow/Blue/WhiteColour`, `Digit0`-`Digit9`, `Dot`, `Next`,
`Previous`, `ChannelStepUp/Down`, `VolumeUp/Down`, `Mute`,
`HeadphonesVolume`, `Play`, `Pause`, `PlayPause`, `Stop`, `FastForward`,
`Rewind`, `Record`, `Online`, `SmartTV`, `PhilipsMenu`, `Setup`,
`AmbilightOnOff`, `PictureStyle`, `SoundStyle`, `SurroundMode`, `3dFormat`,
`3dDepth`, `2PlayerGaming`, `Multiview`. Availability varies by model;
`PlayPause` maps to `Play` and `PowerOff` to `Standby` on Android. One POST
is one complete press — there is no keydown/keyup split. In standby many
models kill the API entirely; power-on is Wake-on-LAN or, on some Android
sets, `POST /6/powerstate {"powerstate": "On"}`.

### Response quirks worth knowing

Command POSTs answer 200 with an empty or junk body (`""`, `"OkOk"`, `"}"`,
`"Context Service not started"`). Booleans arrive as `"On"/"Off"` strings.
Some firmwares emit malformed JSON (doubled commas, a dangling
`"channelList": { "id": "version", "" }` fragment) that haphilipsjs repairs
with string surgery before parsing — a strict parser will choke where a real
TV is merely sloppy. 401 = digest credentials missing/wrong; 403/404 = the
endpoint does not exist on this firmware.

## Remote control surface

The spec's `commands` block names one invocation per remote key (a command's
`arguments` map **is** the JSON body, with an `api_version` parameter feeding
the `/{api_version}/` path prefix), and its `entities` block declares the
remote as `button` entities in remote-layout order: power, navigation and
D-pad, transport, volume, channel stepping, digits, colour keys, then TV
functions.

A stateful **Power** `switch` entity binds `turn_on`/`turn_off` to the
discrete keys, `toggle` to Standby, and the `powerstate` resource as its
state ([Spec Evolution P13](../contributing/spec-evolution.md#p13)); the
`set_power_standby` command writes the same resource — the non-key off for
sets that ignore the PowerOff key. All of it is v6-only, like the read, and
a 403/404 there is endpoint-not-present, not standby.

## Transport gap — read before building on this spec

**JSON request bodies on every POST, plus HTTPS with a self-signed
certificate and HTTP digest auth on 2016+ models — not yet supported by the
reference app.** The app's HTTP transport sends GET/POST with empty bodies
and no auth headers, so no command in this spec is executable by it today,
and its XML-shaped `options_source`/`state_source` select contract cannot
parse this API's JSON channel/app lists either. A client that wants to drive
a Philips TV from this spec must implement: JSON request-body rendering from
a command's `arguments`, TLS with verification skipped (or TOFU pinning),
digest auth, and the two-step PIN pairing flow. The commands are written the
way the TV expects them anyway — an accurate spec with the gap recorded, per
the registry's rule against fake empty-body commands.

## References

- [jointSPACE project page (Wayback Machine)](https://web.archive.org/web/2024/https://jointspace.sourceforge.net/)
- [Official jointSPACE JSON API v1 reference (Wayback Machine)](https://web.archive.org/web/2024/https://jointspace.sourceforge.net/projectdata/documentation/jasonApi/1/doc/API.html)
- [ha-philipsjs — Home Assistant's backend library](https://github.com/danielperna84/ha-philipsjs)
- [pylips — CLI and unofficial v6 API reference](https://github.com/eslavnov/pylips)
- [suborb/philips_android_tv — original 2016 pairing writeup](https://github.com/suborb/philips_android_tv)
- [Home Assistant Philips TV integration](https://www.home-assistant.io/integrations/philips_js/)

Machine-readable spec: `device-specs/devices/philips-jointspace.yaml`
