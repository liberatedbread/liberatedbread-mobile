# Hisense VIDAA TV (remoteapp MQTT)

> **Status**: Documented from community sources; not replayed against hardware by this project
> **Protocol**: WiFi (SSDP/DLNA + MQTT v3.1.1 on TCP 36669, plain/TLS/mTLS by firmware generation)
> **Manufacturer**: Hisense
> **Manufacturer Status**: Active

## Overview

Hisense smart TVs (VIDAA OS, and the earlier Android-based sets) run an
on-device MQTT broker on **port 36669** that exists to serve the official
RemoteNow and VIDAA mobile apps. Everything — remote keys, volume, input
switching, app launching, pairing — is publish/subscribe on topics under
`/remoteapp/`. Hisense publishes nothing about the interface; it was
reverse-engineered by the community (Krazy998 2019, newAM, sehaas, and most
completely warrenrees/pyvidaa, which verified the current credential
algorithm byte-for-byte on a live set in August 2026).

A premise correction worth stating: **no source documents a listener on
port 36668**. The "older remoteapp protocol" is the same broker on 36669
without TLS and with a static login, not a different port.

## Discovery

- **SSDP M-SEARCH** for `urn:schemas-upnp-org:device:MediaRenderer:1` (DLNA
  renderer; also try `ssdp:all`). This target is not Hisense-specific —
  keep only responses whose descriptor has `manufacturer` "Hisense" or a
  `modelDescription` containing `vidaa_support=1` / `transport_protocol=`.
- **Identity**: fetch `http://<ip>:38400/MediaServer/rendererdevicedesc.xml`
  (18400 on some VIDAA versions; try both). `friendlyName` is the display
  name; `modelName` is often literally "Renderer"; the useful identity is
  in `modelDescription`, a newline-separated `key=value` map: `mac`,
  `macEthernet`, `macWifi`, `brand`, `vidaa_support`,
  `transport_protocol` (the auth-generation selector).
- **UDP broadcast** on port 36671 with `{"request":"discover"}` is a
  Hisense-specific alternative used by pyvidaa.
- Keep the MAC(s): Wake-on-LAN is the only power-on path, and it must
  target the interface the TV actually uses (Ethernet far more reliably
  than WiFi).

## Authentication — three generations

Which one a TV speaks follows its `transport_protocol` value (pyvidaa's
thresholds):

| Generation | transport_protocol | Login | TLS |
|---|---|---|---|
| static | < 3000 | `hisenseservice` / `multimqttservice`, client id `{MAC}$normal` or any name | none, self-signed, or mTLS by model |
| legacy dynamic | 3000–3289 | derived per connect from unix time (suffix `h*i&s%e!r^v0i1c9`, plain timestamp) | usually mTLS |
| modern dynamic | ≥ 3290 | same with suffix `h!i@s#$v%i^d&a*a` and timestamp XOR `0x569814772b03a968` | mTLS mandatory |

The dynamic algorithm (MD5 hex, uppercase; `PATTERN =
38D65DC30F45109A369A86FCE866A85B`; `uuid` = client-chosen MAC-shaped id):

- `client_id = {uuid}$his${md5(PATTERN$uuid)[:6]}_vidaacommon_001`
- legacy: `username = his${ts}`, modern: `username = his${ts ^ 0x569814772b03a968}`
- `password = md5({ts}${md5("his" + crosssum(ts)%10 + suffix)[:6]})`

Worked example (pyvidaa, verified on hardware): uuid `56:b8:88:4e:f7:19`,
ts `1766974704` → client_id `56:b8:88:4e:f7:19$his$256DBF_vidaacommon_001`,
username `his$6239759786168176024`, password `C3BA44782E18ABF4892AC44D79A622D2`.

### Pairing

Commands from an unpaired client id are ignored. Pairing puts a 4-digit PIN
on the TV screen (~60 s timeout):

1. Static generation: publish (empty) to
   `/remoteapp/tv/ui_service/{client_id}/actions/gettvstate` → PIN appears →
   publish `{"authNum": "XXXX"}` to `.../actions/authenticationcode` →
   `{"result": 1}` on `/remoteapp/mobile/{client_id}/ui_service/data/authenticationcode`.
2. Modern generation: publish `{"app_version":2,"connect_result":0,"device_type":"Mobile App"}`
   to `.../actions/vidaa_app_connect` → PIN appears (or `{"connect_result":1}`
   means already paired) → `authenticationcode` as above → publish
   `{"refreshtoken": ""}` to
   `/remoteapp/tv/platform_service/{client_id}/data/gettoken` → read
   `accesstoken`/`refreshtoken` (+ durations) from
   `/remoteapp/mobile/{client_id}/platform_service/data/tokenissuance`.
   The accesstoken becomes the MQTT **password** until it expires; refresh
   by re-publishing `gettoken` with the saved refreshtoken.

### The cert-provisioning gap

Modern firmware demands **mutual TLS**, and the TV has no protocol for
enrolling a new client certificate. Every working client presents the cert
baked into the official app (`CN=VidaaAppAndroidV01`, issuer `CN=RemoteCA`),
extracted from the VIDAA APK's PKCS#12 (`assets/client_mobile_android.p12`
or `res/3R.p12`; store password `186e990688070325a1c4b0ce275d2388`).
RemoteNow-era sets that demand certs accept the older
`rcm_certchain_pem.cer` / `rcm_pem_privkey.pkcs8` pair (circulated in
d3nd3/Hisense-mqtt-keyfiles). A clean-room client cannot complete pairing
without redistributing Hisense's key material or having the user extract
it — this, not the topic vocabulary, is the barrier to a fully open
implementation.

## Command channel

Commands publish to `/remoteapp/tv/{service}/{client_id}/actions/{action}`;
replies arrive on `/remoteapp/mobile/{client_id}/{service}/data/{datatype}`
or broadcast topics. Payloads are plain JSON, or a bare string where noted.

| Service | Action | Payload | Notes |
|---|---|---|---|
| `remote_service` | `sendkey` | bare `KEY_*` name | the whole remote — see below |
| `ui_service` | `gettvstate` | empty | also the static-era pairing trigger; **unanswered on some firmware** |
| `ui_service` | `sourcelist` | empty | reply: array of `{sourceid, sourcename, displayname, ...}` |
| `ui_service` | `changesource` | `{"sourceid":"3"}` | ids 0 TV, 1 AV, 2 Component, 3–6 HDMI 1–4 |
| `ui_service` | `applist` | empty | reply: name/appId/url per app |
| `ui_service` | `launchapp` | `{"name":..,"urlType":37,"storeType":0,"url":"netflix"}` | Android-based sets: package name in `url`, `urlType` 0 |
| `ui_service` | `changechannel` | `{"channel_param":"<opaque>"}` | string learned from `livetv` state; no way to construct from a channel number |
| `platform_service` | `getvolume` / `changevolume` | empty / bare `0`–`100` | reply `{"volume_type":0,"volume_value":N}` |
| `ui_service` | `vidaa_app_connect`, `authenticationcode` | JSON | pairing, above |
| `platform_service` | `data/gettoken` | `{"refreshtoken": ..}` | token mint/refresh |

State is broadcast on **`/remoteapp/mobile/broadcast/ui_service/state`**
(retained — a fresh subscriber gets the current state immediately), keyed
by `statetype`: `fake_sleep_0` (standby), `fake_sleep_1` (**waking**, not
asleep), `remote_launcher` (home), `remote_setting`, `sourceswitch`
(external input, carries `sourceid`/`sourcename`/`displayname`), `livetv`
(channel + `channel_param`, EPG on older firmware). Volume broadcasts on
`/remoteapp/mobile/broadcast/platform_service/actions/volumechange`.

The key vocabulary (`sendkey` payload): `KEY_POWER` (toggle — no
power-on key; wake is WoL only), `KEY_UP/DOWN/LEFT/RIGHT/OK`, `KEY_RETURNS`
(back), `KEY_MENU`, `KEY_HOME`, `KEY_EXIT`, `KEY_VOLUMEUP/VOLUMEDOWN/MUTE`,
`KEY_CHANNELUP/CHANNELDOWN`, `KEY_PLAY/PAUSE/STOP/FORWARDS`, `KEY_BACK`
(**rewind**, not back), `KEY_0..KEY_9`, `KEY_RED/GREEN/YELLOW/BLUE`,
`KEY_SUBTITLE`, `KEY_INFO`, plus long-press and pointer-mode variants in
the APK. Power-off is `KEY_POWER`; power-on is **Wake-on-LAN only** — the
broker is down in standby.

## Transport gap

The reference app implements **HTTP (GET/POST, empty body) and SOAP only**.
This device needs an MQTT client with TLS and client-certificate support,
per-connection dynamic credential generation, the PIN pairing flow, token
storage/refresh, and JSON payloads — none of which maps onto either
supported transport. The spec's `commands` therefore declare
`transport: "mqtt"` (schema-legal) and are **not executable by the
reference app today**; they are written so an MQTT transport can run them
unchanged once one exists.

Machine-readable spec: `device-specs/devices/hisense-vidaa.yaml`

## References

- [warrenrees/pyvidaa](https://github.com/warrenrees/pyvidaa) and its
  [VIDAA_PROTOCOL_ANALYSIS.md](https://github.com/warrenrees/pyvidaa/blob/master/VIDAA_PROTOCOL_ANALYSIS.md)
  — primary source for TLS, the credential algorithm, pairing, and 2026-08-04 live findings
- [Krazy998/mqtt-hisensetv](https://github.com/Krazy998/mqtt-hisensetv) — original 2019 topic documentation
- [Krazy998/mqtt-hisensetv issue #14](https://github.com/Krazy998/mqtt-hisensetv/issues/14) — cracking the VIDAA-era dynamic auth
- [newAM/hisensetv](https://github.com/newAM/hisensetv) — static-era Python API/CLI
- [sehaas/ha_hisense_tv](https://github.com/sehaas/ha_hisense_tv) — Home Assistant integration, client-cert era
- [d3nd3/Hisense-mqtt-keyfiles](https://github.com/d3nd3/Hisense-mqtt-keyfiles) — RemoteNow-era client cert pair
- [Home Assistant community thread](https://community.home-assistant.io/t/hisense-tv-control/97638) — six years of model reports
