# Roku External Control Protocol

> **Status**: Complete local discovery and core control documented
> **Protocol**: WiFi (SSDP + HTTP REST on port 8060)
> **Manufacturer**: Roku / TCL
> **Manufacturer Status**: Active

## Overview

Roku TVs and players expose the External Control Protocol (ECP), a local HTTP
API with no authentication. Discovery starts with SSDP `ST: roku:ecp`; the
returned `LOCATION` identifies the host and port, and clients then fetch
`/query/device-info` for stable XML identity.

## Discovery

Use:

```bash
python scripts/roku_discover.py --timeout 5
```

Identity should use `serial-number` first, then `device-id`. The user-facing
name comes from `user-device-name`. AirPlay mDNS (`_airplay._tcp.local.`) can
also locate compatible TCL Roku TVs, but ECP identity should still be fetched
from `/query/device-info`.

## Local API

| Method | Path | Description |
|---|---|---|
| GET | `/query/device-info` | XML identity, model, serial, software version |
| GET | `/query/apps` | Installed apps and app IDs |
| GET | `/query/active-app` | Foreground app |
| GET | `/query/media-player` | Playback state and metadata |
| GET | `/query/icon/<app_id>` | Channel icon (binary image) |
| GET | `/query/tv-channels` | Tuner channels (Roku TV) |
| GET | `/query/tv-active-channel` | Tuned channel with signal info (Roku TV) |
| POST | `/keypress/<key>` | Press and release a remote key |
| POST | `/keydown/<key>` / `/keyup/<key>` | Hold and release a key |
| POST | `/launch/<app_id>` | Launch channel/app, with optional deep link |
| POST | `/install/<app_id>` | Open the Channel Store page for an app |
| POST | `/search/browse?keyword=...` | **Sunset** — removed in Roku OS 12.0 |
| POST | `/input?<name>=<value>` | Sensor/custom input to the running app — does **not** switch TV inputs |

TV input switching is a keypress: `POST /keypress/InputHDMI1` (through
`InputHDMI4`, `InputAV1`, `InputTuner`).

Since Roku OS 14.1, the keypress/keydown/keyup, icon and tv-channel commands
require *Settings > System > Advanced system settings > "Control by mobile
apps" = Enabled*; a device with it disabled answers 403.

The middle **Limited** position refuses more than that notice implies
(probed live 2026-08-11 on OS 15.2.4): `/query/apps` answers *"ECP command
not allowed in Limited mode."* — as **400 on one TV and 403 on two others**,
the same TV switching spellings within minutes — `/query/media-player`
answers 403, and every keypress answers 403, while `/query/device-info` and
`/query/active-app` keep answering 200. Treat the 400-with-that-body as the
same refusal 403 means.

## ECP2: the authenticated WebSocket session

The official Roku app is unaffected by Limited mode because it speaks ECP2,
reverse-engineered from the 14.0 APK's `com.roku.mobile.ecp` stack and
re-implemented live against the fleet on 2026-08-11:

- Connect `ws://<ip>:8060/ecp-session` with subprotocol `ecp-2` and header
  `Sec-WebSocket-Origin: Android`.
- The device sends `{"notify": "authenticate", "param-challenge": "...",
  "param-methods": ["client-id", "jwt"]}`. Client-id auth needs no account:
  answer `{"request": "authenticate", "request-id": "1", "param-response":
  base64(SHA-1(challenge + secret))}`, where the secret ships in the APK
  (`ClientIdChallengeResponseStrategy`): the UUID
  `95E610D0-7C29-44EF-FB0F-97F1FCE4C297` with every hex nibble `n` replaced
  by `(24 - n) & 15`, i.e. `F3A278B8-1C6F-44A9-9D89-F1979CA4C6F1`.
- Frames are `{"request": "query-apps", "request-id": "N"}` →
  `{"response": ..., "status": "200", "content-data": "<base64 XML>"}`.
  Verified on a Limited-mode TV: auth 200, the full channel list,
  `query-active-app`, and `key-press` 200 OK. The request vocabulary is the
  ECP paths dashed (`key-press` takes `param-key`), plus ECP2-only extras
  like `set-textedit-text` (whole-string text entry).

Roku can rotate or revoke the client id in firmware at any time — treat ECP2
as an enhancement over plain ECP with fallback, never the only path.

## Remote control surface

The spec's `commands` block names one invocation per remote key, and its
`entities` block declares the remote as `button` entities in remote-layout
order — power, navigation and D-pad, playback transport, volume, live-TV
channels, then inputs. That is every key the official Roku app's remote
sends over ECP; `scripts/test_roku_spec.py` renders each button from the
YAML alone and diffs the result against the documented key vocabulary.

The spec also declares a stateful **Power** `switch` entity binding the
discrete `PowerOn`/`PowerOff` keys as `turn_on`/`turn_off` roles, so a bulk
operation can resolve power without matching key names
([Spec Evolution P13](../contributing/spec-evolution.md#p13)). `turn_on`
works only from the warm standby "Fast TV Start" keeps; no power state is
readable over ECP.

## Channel launcher

The `Channel` select entity joins three endpoints into a picker: options
come from `/query/apps` (one `<app>` element per installed channel, the
`id` attribute is the launchable value, the text is the name), the current
channel from `/query/active-app` (same shape; **no `id` on the home
screen**, which reads as nothing selected), and choosing an option sends
`POST /launch/{app_id}`. `/query/active-app` stays readable in every gate
position, but `/query/apps` is refused while "Control by mobile apps" is in
its Limited position (above), so the list loads only once the setting is
Permissive/Enabled.

## Text entry

The `Keyboard` `text` entity is the on-screen keyboard's peer: ECP carries no
"type this string" command, only one keypress per character, so the entity
binds `submit` to `type_char` (`POST /keypress/Lit_{char}` — any UTF-8
character percent-encoded after the literal `Lit_` prefix) and `press` to
`press_backspace` for deletion. A client relays each keystroke as it happens,
serialized — two Lit_ POSTs in flight can land reversed — and treats the
remote's OK as the field's submit, exactly as on the physical remote.

Machine-readable spec: `device-specs/devices/roku-ecp.yaml`
