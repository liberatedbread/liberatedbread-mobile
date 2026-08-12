# Vizio SmartCast TV

> **Status**: Research — documented from published reverse-engineering and open clients; not replayed against hardware
> **Protocol**: WiFi (SSDP/mDNS discovery + HTTPS JSON API on port 7345, older sets 9000)
> **Manufacturer**: Vizio
> **Manufacturer Status**: Active

## Overview

Vizio SmartCast TVs (2016+) expose a local HTTPS JSON API. Everything after
pairing is authenticated with a token header; key events, app launching,
input switching and the entire settings tree are reachable locally with no
cloud involvement. The API was never published by Vizio — the reference is
the community [exiva write-up](https://github.com/exiva/Vizio_SmartCast_API),
implemented by [pyvizio](https://github.com/raman325/pyvizio) (Home
Assistant's backend) and the [openHAB
binding](https://www.openhab.org/addons/bindings/vizio/).

> **Transport gap**: a client must implement HTTPS with certificate
> verification disabled (the TV serves a self-signed cert, CN historically
> `BG2.prod.vizio.com`), **PUT** requests with JSON bodies and
> `Content-Type: application/json`, and an **`AUTH` header** carrying the
> paired token. Settings writes are read-modify-write (they must echo the
> current `HASHVAL`). The reference app's `http` transport (GET/POST, empty
> body, no headers) is **not sufficient** — only the unauthenticated GET
> identity reads come close, and even those need the TLS workaround.

## Discovery

Two working signals:

- **SSDP** — search `urn:dial-multiscreen-org:device:dial:1` (DIAL). The
  target is shared by every DIAL-capable TV, so fetch the `LOCATION`
  description document and keep only respondents whose
  `device/manufacturer` is exactly `VIZIO` (this is the filter pyvizio
  applies). `friendlyName`, `modelName` and `UDN` come from the same
  document. The older exiva write-up searched
  `urn:schemas-kinoma-com:device:shell:1`.
- **mDNS** — `_viziocast._tcp.local.`, with TXT keys `name` and `id`.

Once a host is found, identity reads are **unauthenticated**:

| Method | Path | Returns |
|--------|------|---------|
| GET | `/state/device/deviceinfo` | Model name at `ITEMS[0].VALUE.system_info.model_name` |
| GET | `/menu_native/dynamic/tv_settings/system/system_information/tv_information/serial_number` | Serial (primary stable key; pyvizio's pre-pairing unique id) |
| GET | `.../tv_information/version` | Firmware version |

(Newer firmware moved `system_information` under `admin_and_privacy`;
clients try both spellings.)

## Pairing

Run with the TV **on** (pyvizio notes the set can forget the PIN otherwise).
Pairing endpoints need no auth:

1. `PUT /pairing/start` with `{"DEVICE_ID": "...", "DEVICE_NAME": "..."}` —
   the TV shows a **4-digit PIN** at the top of the screen; the response's
   `ITEM` carries `PAIRING_REQ_TOKEN` and `CHALLENGE_TYPE`.
2. `PUT /pairing/pair` with `DEVICE_ID`, `CHALLENGE_TYPE`,
   `RESPONSE_VALUE` (the PIN, as a string) and `PAIRING_REQ_TOKEN` — the
   response's `ITEM.AUTH_TOKEN` is the credential to store.
3. `PUT /pairing/cancel` aborts (RESPONSE_VALUE hard-coded `"1111"`).

Failure verdicts live in `STATUS.RESULT`: `PAIRING_DENIED` (wrong PIN),
`MAX_CHALLENGES_EXCEEDED`, `BLOCKED` (another pairing in progress). Every
subsequent request sends `AUTH: <token>`. The paired client appears under
*Settings > System > Mobile Devices* on the TV, and the token survives
until deleted there or a factory reset.

**Response envelope**: every reply is 200 OK with a JSON body whose
`STATUS.RESULT` is the real verdict (`success`, `failure`,
`uri_not_found`, `requires_pairing`, `invalid_parameter`, ...) — HTTP
status codes are not meaningful.

## Local API

Base URL `https://<ip>:7345` (firmware 4.0+; `:9000` on older sets; HTTPS
only, self-signed cert).

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| PUT | `/pairing/start` | no | Show PIN, get pairing token |
| PUT | `/pairing/pair` | no | Trade PIN for `AUTH_TOKEN` |
| PUT | `/pairing/cancel` | no | Abort pairing |
| GET | `/state/device/deviceinfo` | no | Model/identity document |
| GET | `.../tv_information/serial_number` | no | Serial number |
| GET | `/state/device/power_mode` | yes | `ITEMS[0].VALUE`: 1 on, 0 standby |
| PUT | `/key_command/` | yes | Remote key events (see below) |
| GET | `/app/current` | yes | Foreground app `{APP_ID, NAME_SPACE, MESSAGE}` |
| PUT | `/app/launch` | yes | Launch app by catalogue triple |
| GET | `/menu_native/dynamic/tv_settings/devices/name_input` | yes | Input list (`ITEMS[x].NAME` = switchable name) |
| GET | `.../devices/current_input` | yes | Active input + `HASHVAL` |
| PUT | `.../devices/current_input` | yes | Switch input (`REQUEST: MODIFY`, `VALUE`, `HASHVAL`) |
| GET | `/menu_native/dynamic/tv_settings/<cname>` | yes | Read a settings group |
| PUT | `/menu_native/dynamic/tv_settings/<cname>/<item_cname>` | yes | Write a setting (read-modify-write with `HASHVAL`) |

### Key commands

`PUT /key_command/` with body
`{"KEYLIST": [{"CODESET": int, "CODE": int, "ACTION": "KEYPRESS"}]}`
(`KEYDOWN`/`KEYUP` for holds; several entries chain). The full table as
implemented in the spec's `commands` block:

| Codeset | Family | Keys |
|---------|--------|------|
| 0 | ASCII | channel digits 0–9 = codes 48–57 (tuner-less models reject them) |
| 2 | Transport | seek_fwd 0, seek_back 1, pause 2, play 3 |
| 3 | D-pad | down 0, left 1, ok 2, right 7, up 8 |
| 4 | Navigation | back 0, smartcast 3, cc_toggle 4, info 6, menu 8, home 15 |
| 5 | Audio | vol_down 0, vol_up 1, mute_off 2, mute_on 3, mute_toggle 4 |
| 6 | Video | pic_mode 0, pic_size 2 |
| 7 | Input | input_next 1 |
| 8 | Channel | ch_down 0, ch_up 1, ch_prev 2 |
| 9 | Color | exit 0 |
| 11 | Power | off 0, on 1, toggle 2 |

Home Assistant documents a `guide` command whose codeset/code pair appears
in neither pyvizio nor the exiva tables — not catalogued.

### Apps

The TV does **not** enumerate its installed apps. Launch and identify by
the `(APP_ID, NAME_SPACE, MESSAGE)` triple from Vizio's app catalog —
clients ship a bundled copy (pyvizio's `pyvizio/data/apps.json`).
`NAME_SPACE` 2 and 4 are interchangeable; `NAME_SPACE` 0 from
`/app/current` means a cast session. While an app runs, `current_input`
reads `SMARTCAST`/`CAST`.

### Settings tree

`/menu_native/dynamic/tv_settings/<cname>` reads groups (picture, audio,
timers, network, channels, closed_captions, devices, system,
mobile_devices, cast); `/menu_native/static/tv_settings/<cname>` lists
allowed choices. Writes **must** echo the item's current `HASHVAL`
(optimistic concurrency), and the value type follows the item's `TYPE`.
exiva warns an invalid value can brick sets — honour the static options.

### Power and wake

The API server is **down while the set sleeps**: a sleeping TV is
unreachable, not answerable. Wake needs a Wake-on-LAN magic packet, which
does not work in *Settings > System > Power Mode > Eco Mode*; Quickstart
mode keeps the network warm enough.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — on-screen onboarding, then per-client pairing |
| Method | `device_ui` |
| Passphrase protection | not_applicable (entered on the TV) |
| Confidence | medium (public sources, not replayed) |

**Factory reset**: *Settings > System > Reset & Admin > Reset TV to Factory
Defaults* (older firmware: *Admin & Privacy*), administrative passcode
(default `0000`), confirm. Clears network credentials, settings, and the
paired-device list — i.e. every issued token.

**Rebinding to a new network**: in place via *Settings > Network*; no
factory reset needed, tokens survive.

## References

- [exiva — Vizio SmartCast API (2016+ Models)](https://github.com/exiva/Vizio_SmartCast_API)
- [pyvizio](https://github.com/raman325/pyvizio) (maintenance mode; successor `vizaio`)
- [Home Assistant VIZIO SmartCast integration](https://www.home-assistant.io/integrations/vizio/)
- [openHAB Vizio binding](https://www.openhab.org/addons/bindings/vizio/)
- [Lifewire — Vizio factory reset and Power Mode menu paths](https://www.lifewire.com/fix-vizio-tv-that-keeps-turning-on-and-off-5198526)

Machine-readable spec: `device-specs/devices/vizio-smartcast.yaml`
