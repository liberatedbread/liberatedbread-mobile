# Netgear Meural Canvas I & II — Local API Research Notes

## What it is
Meural Canvas / Canvas II (MC315 / MC321 / MC327, 21.5" and 27") WiFi digital
art frames. Meural was acquired by Netgear in 2018. Frames run a local web
server (Netgear's own support docs call it the "remote controller") alongside
the Meural cloud service.

## Company status (dated sources)
- Netgear killed the Meural product line in 2024; selling through remaining
  inventory (channelnews.com.au, 2024-05-09).
- Netgear community staff (2025-11-24): "The Meural Canvas has not been
  discontinued, and there are no plans to date to remove the Meural app" —
  conflicting signals; product line is dead, service still up.
- Third-party watch site nimbusdigitalart.com/meural (2026-06): app unmaintained
  >1 year, Alexa skill gone; cloud shutdown is a when-not-if risk.
- As of 2026-08-07 the local interface documented below works regardless of
  cloud state.

## Local interface — confirmed
The Canvas runs an unauthenticated HTTP server on port 80. Netgear documents it
as a browser "remote controller" (KB000060746). The JS driving it is readable
at `http://<canvas-ip>/static/remote.js`; endpoint list below transcribed from
the ha-meural project (GuySie/ha-meural, github.com):

- `GET /remote/identify/` — device identification
- `GET /remote/get_galleries_json/` — playlists/albums loaded on the frame
- `GET /remote/get_gallery_status_json/` — current item/playlist state
- `GET /remote/get_frame_items_by_gallery_json/`
- `GET /remote/get_wifi_connections_json/`
- `GET /remote/get_backlight/`
- `GET /remote/control_check/sleep|video|als|system/` — status incl. ambient
  light (lux) and WiFi signal (dBm)
- `GET /remote/control_command/boot_status/image/`
- `GET /remote/control_command/set_key/<key>/`
- `GET /remote/control_command/set_backlight/<0-100>/`
- `GET /remote/control_command/suspend` / `resume` — sleep / wake
- `GET /remote/control_command/set_orientation/<landscape|portrait>/`
- `GET /remote/control_command/change_gallery/<id>/`
- `GET /remote/control_command/change_item/<id>/`
- `GET /remote/control_command/rtc/` `language/` `country/`
- `GET /remote/control_command/als_calibrate/off/`
- `POST /remote/control_command_post/connect_to_new_wifi/` (+ `_exist_`,
  `_hidden_`, `delete_wifi_connection/`)
- `POST /remote/postcard/` — push an image to the frame locally ("postcard")

No auth, no token, no cloud round-trip. Discovery: DHCP/ARP scan or router
client list; frames announce hostname like `picasso-428`.

## Offline content path (no API needed)
Canvas II plays images from an SD card in folders `meural1`–`meural4`;
switchable via the local API `change_gallery`. Fully air-gappable.

## What needs cloud
- Initial pairing, Meural art-store content, firmware updates.
- The ha-meural integration logs into the Netgear account once (for cloud-side
  playlist push), but all runtime control above is local. After cloud death,
  expect: local API + SD card keep working; new-playlist upload via postcard
  endpoint is the open question.

## Existing implementations
- Home Assistant core `meural` integration (iot_class local_polling) — on/off,
  brightness via the same local endpoints.
- GuySie/ha-meural (HACS) — full media-player model on local + cloud APIs.
- Unofficial cloud REST API docs: documenter.getpostman.com/view/1657302/RVnWjKUL

## APK
Companion app exists (`com.netgear.meural`) but unnecessary: the local protocol
is fully observable in `remote.js` (plain JS on the device). Not fetched.

## Open questions
1. Exact multipart schema of `POST /remote/postcard/` (transcribe from
   remote.js during spec work).
2. `set_key` key values for gesture-equivalent navigation.
3. Does the local server survive a frame that was never cloud-paired? (Buy used
   → factory reset → local-only setup needs verification.)
