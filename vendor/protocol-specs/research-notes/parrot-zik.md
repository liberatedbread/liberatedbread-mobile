# Parrot Zik (1 / 2.0 / 3) — Research Notes

Date researched: 2026-08-03. Researcher: BT-Classic audio swarm.

## Verdict
**CONFIRMED viable, easy.** Bluetooth Classic SPP (RFCOMM) control channel, fully
reverse-engineered by the community, no account or cloud needed for local control.
Text-based REST-ish API (`GET /api/...`) over a trivially-framed serial socket.
Company (Parrot SA) pivoted to professional drones and abandoned consumer audio;
headphone line discontinued, app unmaintained.

## Cloud / company status
- Parrot SA exited consumer audio; the Zik line was last sold ~2017 and is long
  discontinued. Parrot survives as a B2B/professional drone company, so there is
  no rescue coming for the app.
- The official app `com.parrot.zik2` ("Parrot Zik", covers Zik 2.0/3) is
  unmaintained; users report newer app builds dropped Zik 1 support and old
  phones/accounts cause "No Devices Found" confusion
  ([AVForums thread, 2019](https://www.avforums.com/threads/parrot-zik-headphones-original-v1-what-app-do-i-need-to-control-them.2242712/)).
- Parrot still hosts a stale Zik support/documentation page
  ([parrot.com/en/support/documentation/zik](https://www.parrot.com/en/support/documentation/zik)).
- Cloud dependency: OPTIONAL. Producer/artist EQ presets were downloaded from
  Parrot servers (`/api/audio/preset/download`); those servers are presumed dead.
  All device settings (ANC, EQ, sound effects, head detection, auto power-off,
  TTS, flight mode) are local SPP commands — no login in the app.

## Companion app / APK provenance
- **Package**: `com.parrot.zik2` (internal code namespace `com.elinext.parrotaudiosuite` —
  Parrot outsourced the app to Elinext)
- **Version**: 1.91 (versionCode 219004)
- **Source**: apkeep, apk-pure
- **APK SHA-256**: `567bffc99603cef2362c7e25772c73b7d20eac983cdf8eba2997604dee9dc729`
- **Decompiled**: jadx → `$REPO/workspace/static/parrot-zik/` (unobfuscated, clean)
- Zik 1 was controlled by the older "Parrot Audio Suite" app (`com.parrot.zik`,
  not fetched this pass — likely also on apk mirrors).

## Transport (from static analysis + community)
- Bluetooth Classic RFCOMM, **insecure** socket (`createInsecureRfcommSocketToServiceRecord`),
  no PIN beyond normal BT pairing. A2DP + HFP used for audio alongside.
- SPP service UUIDs (`BTManager.java`):
  - Zik 2.0: `8b6814d3-6ce7-4498-9700-9312c1711f63`
  - Zik 3:   `8b6814d3-6ce7-4498-9700-9312c1711f64`
  - Zik 1: TBD (present in Zik_Manager source; pattern suggests `...1f62`)
- The app discovers the already-A2DP-connected device, resolves the RFCOMM
  channel via SDP, then opens a session with a 3-byte header (type 0x00).

## Protocol framing (`Protocol.java`)
- Header: 2-byte big-endian length (payload_len + 3) + 1-byte type.
- Types: `0x00` open session, `0x80` data; firmware-upload packets embed
  pktType/pktId fields (see `BTManager.ConnectedThread.pars`).
- Payload: ASCII text. Requests are `GET /api/<path>` or
  `GET /api/<path>?<args>` (even "set" operations use the `GET ` verb, e.g.
  `GET /api/audio/noise_control/enabled/set?value=true` — arg prefix constant `ARG`).
- Multi-part responses carry x/y fragment counters (`InMessage`).

## API surface (from `ZikAPI.java`, ~60 endpoints; all local)
- `/api/system/battery/get`, `/api/software/version/get`,
  `/api/bluetooth/friendlyname/get|set`, `/api/system/device_type`
- ANC: `/api/audio/noise_control/enabled/set`, `.../get`, `.../auto_nc/set`,
  `.../phone_mode/get|set`
- EQ: `/api/audio/equalizer/enabled/get|set`, `/api/audio/thumb_equalizer/value/...`,
  `/api/audio/param_equalizer/value/set`, preset activate/save/remove/clear_all
- Spatializer: `/api/audio/sound_effect/enabled|angle|room_size/...` ("Concert Hall")
- Misc: `/api/system/head_detection/enabled/set`, `/api/system/auto_power_off/...`,
  `/api/system/flight_mode/get`, TTS, audio delay, `/api/audio/source/get`,
  `/api/audio/track/metadata/get`

## Prior community reverse engineering
- [lainwir3d/Zik_Manager](https://github.com/lainwir3d/Zik_Manager) — unofficial
  Qt manager for Zik 1/2.0/3 (Windows/Linux/OSX/Android/Sailfish): ANC, EQ,
  spatializer, head detection, auto-off, flight mode, TTS. Complete protocol impl.
- [devmil/parrot-zik-2-supercharge](https://github.com/devmil/parrot-zik-2-supercharge) —
  patches the official app to expose an Android API (battery widget, ANC toggle).
- dpin.de user write-up confirming the protocol was hacked early, with Linux tray
  applet + Qt app ([dpin.de/nf/parrot-zik-2-0](https://www.dpin.de/nf/parrot-zik-2-0/)).

## Feasibility / next steps
1. Spec the framing + full `/api` table from `ZikAPI.java` + Zik_Manager sources
   (both in hand) — no device capture strictly required.
2. Validate against a real Zik 2.0/3 with `rfcomm`/`pyserial`: open session, send
   `GET /api/system/battery/get`, parse response.
3. Firmware update path exists in-app (`UpdateManager.java`, OTA over SPP) —
   document but treat carefully (brick risk; firmware images were cloud-hosted).
- safety_class: LOW (consumer headphones; hearing-damage caveat only).

## Open questions
- Zik 1 RFCOMM UUID (check Zik_Manager source).
- Do Parrot preset-download servers still respond? (irrelevant for local control)
- Whether insecure RFCOMM works from desktop BlueZ without prior pairing (likely yes).
