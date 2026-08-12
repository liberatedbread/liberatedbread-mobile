# Panasonic Viera Network Remote Control

> **Status**: Complete local discovery and control documented from community sources (nothing replayed against hardware here)
> **Protocol**: WiFi (SSDP + SOAP over HTTP on port 55000)
> **Manufacturer**: Panasonic
> **Manufacturer Status**: Active

## Overview

Panasonic Viera smart TVs (Viera Cast 2011-2014, Firefox OS 2015-2018, My
Home Screen 2019+) expose an undocumented local SOAP/UPnP remote-control API
on TCP port 55000. On pre-2019 sets it is completely unauthenticated; from
circa 2019 (FZ/GZ/HZ/JZ and later) every command rides inside an
AES-128-CBC + HMAC-SHA-256 envelope after a one-time PIN-on-screen pairing.
The reference implementation of both generations is the
[panasonic-viera Python library](https://github.com/florianholzapfel/panasonic-viera),
which Home Assistant's
[Panasonic Viera integration](https://www.home-assistant.io/integrations/panasonic_viera/)
drives daily.

## Discovery

SSDP M-SEARCH with search target `urn:panasonic-com:device:p00RemoteController:1`;
the `LOCATION` header points at `http://<ip>:55000/nrc/ddd.xml`, the UPnP
device description. Identity comes from that document: `UDN` (unique id —
observed Viera UDNs start `uuid:4D454930-`), `friendlyName` for display, and
`modelNumber`. The sets also answer `ssdp:all`, but the
`p00RemoteController:1` target is the identifying signal.

Generation detection: fetch `http://<ip>:55000/nrc/sdd_0.xml` (the NRC
service description). If its action list contains `X_GetEncryptSessionId`,
the set requires PIN pairing and encrypted commands; otherwise plain SOAP
works. Do not guess from the model string.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (on the TV's own screen) |
| Method | `device_ui` |
| Passphrase protection | not_applicable (WiFi is configured on the TV) |
| Client pairing | Only on 2019+ sets: PIN shown on TV, one SOAP exchange |
| Confidence | medium (public sources; not run here) |

On the TV: complete first-run setup, join the network, then check
**Settings > Network > TV Remote App Settings** — enable network remote
control, and **"Powered On By Apps" / "Networked Standby"** if power-on over
the network is wanted (naming varies by model year). Without network standby
the set answers nothing while off; Wake-on-LAN is the fallback, and several
older plasma models on Home Assistant's supported list cannot power on over
the network at all.

**Client pairing (2019+ sets only)** — one-time, yields an
`X_ApplicationId`/`X_Keyword` credential pair to store:

1. Client sends `X_DisplayPinCode` with `<X_DeviceName>`; the TV overlays a
   4-digit PIN and the response carries `X_ChallengeKey` (16 bytes, base64).
2. Client encrypts `<X_PinCode>{pin}</X_PinCode>` with AES-128-CBC keys
   derived from the challenge (key = reversed, bitwise-NOTed 4-byte groups of
   the challenge; HMAC key = a fixed 32-byte mask from the official app's
   `libtvconnect.so` XORed against the rotated challenge) and sends it to
   `X_RequestAuth` inside `<X_AuthInfo>`. Error code 600 = wrong PIN.
3. The `X_AuthResult` reply decrypts to `<X_ApplicationId>` and
   `<X_Keyword>` — store both.

Each session then opens with `X_GetEncryptSessionId` and every command rides
in `X_EncryptedCommand` with a per-session sequence counter. The byte-level
detail (payload framing, both key derivations, the session-key swap) is in
`nrc_common.encrypted_session` in the machine-readable spec.

**Factory reset**: Menu > Setup > System Menu > Factory Defaults (some model
years: "Shipping Condition") — clears network credentials, paired clients,
account link and settings. Confidence low; the menu path varies by
generation and region. Rejoining a new WiFi network only requires re-running
the network setup from the TV menu, never a factory reset.

## Protocol Summary

All control is SOAP POSTs on port 55000:

| Service | Control URL | Purpose |
|---|---|---|
| `urn:panasonic-com:service:p00NetworkControl:1` | `/nrc/control_0` | Remote keys, queries, app launch, pairing |
| `urn:schemas-upnp-org:service:RenderingControl:1` | `/dmr/control_0` | Absolute volume 0-100 and mute (plain SOAP on both generations) |

### NRC actions

| Action | Arguments | Description |
|---|---|---|
| `X_SendKey` | `X_KeyEvent` = `NRC_*-ONOFF` | One press-and-release of a remote key |
| `X_RemoteControl` | `X_KeyEvent` | Older spelling of the same function on some firmware |
| `X_GetVectorInfo` | — | Device/node info string |
| `X_GetAppList` | — | Flat string of installed apps with `product_id`s |
| `X_LaunchApp` | `X_AppType` = `vc_app`, `X_LaunchKeyword` = `product_id=...` | Launch an app |
| `X_DisplayPinCode` / `X_RequestAuth` / `X_GetEncryptSessionId` | pairing | 2019+ sets only |
| `X_EncryptedCommand` | `X_ApplicationId`, `X_EncInfo` | Wrapper every other NRC action rides in on 2019+ sets |

Example — pressing Home:

```xml
POST /nrc/control_0 HTTP/1.1
Host: <tv-ip>:55000
Content-Type: text/xml; charset=utf-8
SOAPACTION: "urn:panasonic-com:service:p00NetworkControl:1#X_SendKey"

<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:X_SendKey xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">
<X_KeyEvent>NRC_HOME-ONOFF</X_KeyEvent>
</u:X_SendKey>
</s:Body>
</s:Envelope>
```

Errors come back as HTTP 500 with a SOAP Fault carrying `errorCode` /
`errorDescription` — do not treat the HTTP status alone as a transport
failure.

### Key vocabulary

The full `NRC_*-ONOFF` vocabulary is in
[keys.py](https://github.com/florianholzapfel/panasonic-viera/blob/master/panasonic_viera/keys.py):
navigation (`NRC_UP/DOWN/LEFT/RIGHT/ENTER/RETURN/CANCEL/HOME/MENU/SUBMENU/INFO/EPG`),
playback (`NRC_PLAY/PAUSE/STOP/REW/FF/SKIP_PREV/SKIP_NEXT/REC/30S_SKIP`),
volume (`NRC_VOLUP/VOLDOWN/MUTE`), tuner (`NRC_CH_UP/CH_DOWN/R_TUNE/D0-D9`),
inputs (`NRC_CHG_INPUT`, `NRC_TV`, and the undocumented `NRC_HDMI1-4`),
colour buttons, `NRC_TEXT/STTL/ASPECT`, and app keys (`NRC_APPS`,
`NRC_NETFLIX`, `NRC_MYAPP` — the latter two undocumented but working per
Home Assistant's docs). The spec's `commands` block carries one SOAP
invocation per key; its `entities` block lays the remote out as `button`
entities.

## Transport gap

**2019+ sets are NOT controllable by the reference app today.** Its `soap`
transport renders plain SOAP envelopes, which is all pre-2019 sets need. The
encrypted generation additionally requires: AES-128-CBC and HMAC-SHA-256
wrapping of every NRC command, base64, a persistent per-session sequence
counter, stored pairing credentials, and the PIN pairing flow itself — all
documented byte for byte in `nrc_common.encrypted_session` of the spec. A
consumer must implement that wrapper around the same SOAP POST; until it
does, the buttons in `entities` work only against pre-2019 sets. The DMR
volume/mute service is plain SOAP on both generations and works today.

`X_GetAppList`'s reply is a flat quote-delimited string, not XML elements,
so the schema's `options_source` select contract cannot consume it — the
`App` select carries the widely-deployed `product_id`s from
[apps.py](https://github.com/florianholzapfel/panasonic-viera/blob/master/panasonic_viera/apps.py)
as static options instead.

## References

- [panasonic-viera — Python library (protocol reference implementation)](https://github.com/florianholzapfel/panasonic-viera)
- [Home Assistant Panasonic Viera integration](https://www.home-assistant.io/integrations/panasonic_viera/)
- [Home Assistant config_flow.py — UDN as unique id, pairing step](https://raw.githubusercontent.com/home-assistant/core/dev/homeassistant/components/panasonic_viera/config_flow.py)
- [Turgon37/panasonic-viera fork — SSDP discovery](https://github.com/Turgon37/panasonic-viera/blob/master/panasonic_viera/remote_control.py)
- [LogicMachine forum — independent Lua implementation, live power-toggle confirmation, encrypted-flow port](https://forum.logicmachine.net/showthread.php?tid=232)
- [uc-intg-panasonicviera — Unfolded Circle integration](https://github.com/mase1981/uc-intg-panasonicviera)

Machine-readable spec: `device-specs/devices/panasonic-viera.yaml`
