# Samsung The Frame — Art Mode Local API Research Notes

## What it is
Samsung "The Frame" lifestyle TV line (2017–present, all sizes 32"–85"),
a Tizen smart TV with an Art Mode that shows artwork/photos on a matte
low-power panel when "off". Company very much alive; local control is the
standard path for all Samsung Tizen TVs — documenting it here because the
art-mode endpoints make it the best *actively maintained* art-frame target
in this category.

## Local interface — confirmed
Standard Samsung Tizen local API (same as all 2016+ Samsung TVs):

- **WebSocket control channel**: `ws://<tv-ip>:8001/api/v2/channels/samsung.remote.control`
  (plain) or `wss://<tv-ip>:8002/...` (TLS, 2018+ models). Name token in the
  URL is base64; first connection pops an on-TV Allow/Deny prompt — that
  pairing is fully LOCAL, no account.
- **REST device info**: `http://<tv-ip>:8001/api/v2/` (model, OS, token
  support flag). 8002 HTTPS equivalent on newer sets.
- **Art Mode API**: exposed over the same websocket as a sub-channel
  (`com.samsung.art-app`). Implemented in the Python lib `samsungtvws`
  (xchwarze/samsung-tv-ws-api) as `tv.art()`:
  - `available()` / `supported()` — is art mode present
  - `get_current()`, `set_artwork(content_id)` — query/select displayed art
  - `get_art_list()`, `get_thumbnail()`, `upload(file)` (JPEG/PNG),
    `delete()`, `delete_list()`
  - `set_brightness`, `set_color_temperature`, matte/style, filters,
    slideshow interval, `set_favourite`
- **Discovery**: SSDP / UPnP (`urn:samsung.com:device:RemoteControlReceiver:1`),
  plus mDNS on newer firmware; also upnp device description on port 8001.
- **Power-on caveat**: Wake-on-LAN (magic packet) works when the TV is in
  standby; in Art Mode the panel is on but the "TV" is logically off.

## Existing implementations
- `samsungtvws` Python library (github.com/xchwarze/samsung-tv-ws-api) —
  reference implementation incl. art mode.
- Home Assistant core `samsungtv` integration (local push) — power, source,
  media keys.
- HACS `TheFab21/ha-samsungtv-smart` — full art-mode control: artwork
  selection, upload, brightness, matting, filters, slideshow.
- Writeup: jonsully.net/blog/samsung-frame-art-api (2024-11-23) — scripting
  personal photography onto the Frame.

## What needs cloud
Nothing. SmartThings app (cloud) is Samsung's *consumer* path but is not
required — token pairing, art upload, and all control are LAN-local.
Firmware updates optionally OTA but not required for operation.

## Model notes
- 2016–2017 (Tizen 2.4/3.0): port 8001 plain WS, no token.
- 2018+ : port 8002 WSS + pairing token persisted by client.
- Art upload via API works on 2021+ models (samsungtvws >= 0.2); older sets
  can select/delete built-in art but upload may fail (TLS framing differs).

## APK
Samsung's companion path is SmartThings (irrelevant to the local API).
Not fetched.

## Safety / notes
None beyond normal TV. The Frame's One Connect box and low-power art panel
have no actuator risk.
