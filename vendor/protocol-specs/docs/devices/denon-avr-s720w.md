# Denon AVR-S720W

> **Status**: Spec Available — discovery observed on live hardware, control surface documented from published sources (not replayed here)
> **Protocol**: WiFi (HTTP `/goform/` on port 80, ASCII control on port 23, UPnP MediaRenderer)
> **Manufacturer**: Denon (IEEE registers its OUI to D&M Holdings Inc.)
> **Manufacturer Status**: Active

## Overview

A 2016 7.2-channel Denon receiver, and a good example of a device whose local
control is *easier* than its discovery. There is no account, no pairing, no
token and no session: anything that can route to the receiver has full control
of it. The hard part is recognising it — everything it announces on the
network is a generic standard.

Four surfaces live on one address:

| Surface | Port | What it is good for |
|---|---|---|
| `/goform/` HTTP API | 80 | Everything a remote does. No session, no auth. Undocumented. |
| Denon/Marantz ASCII control | 23 | The same vocabulary, **plus** unsolicited state push. One client at a time. Vendor-published. |
| UPnP MediaRenderer | from SSDP `LOCATION` | Handing the receiver a media URL to play — the one thing goform cannot do. |
| AirPlay 1 + Spotify Connect | from mDNS SRV | Streaming sinks, not control. Their TXT records are the best identification signal the unit emits. |

The two control routes carry the *same* commands:
`GET /goform/formiPhoneAppDirect.xml?PWON` and a `PWON\r` written to port 23 do
the same thing. So a consumer that speaks only HTTP loses nothing but the push —
which is why every entity in the machine-readable spec binds over HTTP.

## Discovery

Nothing this receiver advertises is vendor-specific on its face:

- **mDNS**: `_http._tcp`, `_airplay._tcp`, `_raop._tcp`, `_spotify-connect._tcp`
- **SSDP**: `upnp:rootdevice`, its UDN, `urn:schemas-upnp-org:device:MediaRenderer:1`,
  and the three standard renderer services (`RenderingControl`,
  `ConnectionManager`, `AVTransport`)
- **Hostname**: `Denon-AVR-S720W.local` — model-derived, but it changes when the
  owner renames the receiver

Three details do the identifying instead, and all three were observed live:

1. **The SSDP `SERVER` header** reads `KnOS/3.2 UPnP/1.0 DMP/3.5`. KnOS is D&M's
   firmware platform; a `SERVER` containing `KnOS/` promotes a generic
   MediaRenderer hit to a positive vendor identification *before* any HTTP
   request.
2. **The UDN's node field is the MAC** —
   `uuid:XXXXXXXX-XXXX-XXXX-XXXX-0005CDAABBCC`. `00:05:CD` is D&M's OUI, so a
   UDN ending in twelve hex digits that start `0005cd` is a D&M device — a
   second vendor signal with no HTTP fetch, and the receiver's stable identity.
   It is *not* a join key against the AirPlay `deviceid`: a receiver has a
   wired and a wireless MAC, and the two records may carry different ones.
   Join an SSDP hit to an mDNS hit by address.
3. **The Spotify Connect `cpath`** is `/goform/spotifyConfig`. `/goform/` is
   D&M's own web-API namespace — this is the strongest single mDNS signal on the
   unit, despite being a third party's protocol.

The AirPlay TXT records carry the model string in two places (`am` and `model`,
both `AVRS720W`) and the AirPlay generation in two more (`srcvers` and `vs`, both
`190.9.p6` — AirPlay 1, with no `pk` record, so AirPlay-2-only senders will not
see this receiver at all).

Two of the three signals are machine-matchable, and the spec declares them as
`mdns_txt_match` conditions rather than leaving them as prose: `cpath` equal to
`/goform/spotifyConfig` on `_spotify-connect._tcp`, and a `deviceid` starting
`00:05:CD` on `_airplay._tcp` (with `am` starting `AVR` on `_raop._tcp` as a
weaker third). Only the `SERVER` header stays prose — the schema has no
SSDP-reply matcher yet. All of these say "a D&M device", never "this unit":
identity is the UDN or the AirPlay `deviceid` value.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — Ethernet, or on the receiver's own on-screen menu |
| Method | `wired` — plug into the NETWORK port, no menu interaction — or `device_ui` (Wi-Fi, WPS, or credentials copied over USB from an iOS device) |
| Passphrase protection | not_applicable — it is typed on the receiver, never handed to it by a client |
| Client pairing | None. There is no authentication anywhere on the local surface. |
| Confidence | medium (published sources; not run here) |

The step that matters for every consumer of this spec is not the network join —
it is the one after it:

> **Setup > Network > Network Control > Always On**

With it off, the receiver's *entire* LAN surface — HTTP, port 23, UPnP and mDNS
alike — is powered down in standby, and no client can bring it back up. No
Wake-on-LAN path is documented for this generation. The trade-off is real and
the user's: "Always On" raises idle draw, and Denon ships it off on some model
years.

**Factory reset** — two different operations, and they are not interchangeable:

- *Network settings only*: **Setup > Network > Reset**. What you want when
  moving to a new router.
- *Full microprocessor reset*: standby, then hold **TUNER PRESET CH +** and
  **TUNER PRESET CH −** while pressing power, releasing when the display
  flashes. This also discards the Audyssey calibration — an hour of somebody's
  afternoon with a measurement microphone.

Neither has been performed by this project, and the front-panel button pair
varies across the S-series, so confirm it against the unit's own manual first.
Rebinding to a new network never needs a reset: re-run **Setup > Network >
Connection**, and note that Ethernet takes precedence over Wi-Fi automatically
when a cable is present.

## Protocol Summary

### Reading state

| Method | Path | Description |
|--------|------|-------------|
| GET | `/goform/formMainZone_MainZoneXmlStatusLite.xml` | Power, input, volume, mute. **Poll this one.** |
| GET | `/goform/formMainZone_MainZoneXml.xml` | Adds `FriendlyName`, `Model`, `ZonePower`, `SurrMode`, `InputFuncList`, `RenameSource`. Fetch once per connection. |
| GET | `/goform/formNetAudio_StatusXml.xml` | Now-playing for the network sources. |
| GET | `/goform/Deviceinfo.xml` | Model, MAC, zone count, AppCommand generation — where it exists; treat a 404 as normal. |
| POST | `/goform/AppCommand.xml` | Batched named queries in one round trip. |

Replies are namespace-free XML rooted at `<item>`, with almost every reading
wrapped one level deeper in a `<value>` child:

```xml
<?xml version="1.0" encoding="utf-8"?>
<item>
  <Power><value>ON</value></Power>
  <InputFuncSelect><value>MPLAY</value></InputFuncSelect>
  <VolumeDisplay><value>Relative</value></VolumeDisplay>
  <MasterVolume><value>-40.0</value></MasterVolume>
  <Mute><value>off</value></Mute>
</item>
```

### Sending commands

| Method | Path | Description |
|--------|------|-------------|
| GET | `/goform/formiPhoneAppDirect.xml?<CMD>` | Any ASCII command, sent exactly as port 23 takes it, with no terminator. |
| GET | `/goform/formiPhoneAppPower.xml?1+PowerOn` | Power on/standby for zone 1. |
| GET | `/goform/formiPhoneAppVolume.xml?1+-40.0` | Absolute volume in **dB**. |
| GET | `/goform/formiPhoneAppMute.xml?1+MuteOn` | Mute on/off. |

The ASCII vocabulary is `PW` (unit power), `ZM` (main zone), `MV` (volume),
`MU` (mute), `SI` (input), `MS` (surround), `SLP` (sleep timer) and `PS` (audio
parameters); appending `?` queries instead of setting.

Control GETs answer 200 with an empty or stub body **whether or not the command
was meaningful**. The response acknowledges receipt, not effect — re-read a
status document to find out what actually happened.

## Things that bite

- **Volume is expressed two different ways on two routes that both work.** The
  status documents and `formiPhoneAppVolume.xml` use signed dB. The ASCII `MV`
  command uses an offset integer where `80` is the 0 dB reference — the two
  differ by 80 (`dB = MV − 80`), and a third digit is a half step (`MV505` =
  −29.5 dB). So a reading of `−20.0` goes back as `−20.0` on the goform route
  but as `MV60` on the ASCII one; send `MV20` instead and you get −60 dB.
  **−40 dB is the one level where both encodings share their digits** (−40 dB
  *is* `MV40`), so testing the round-trip at −40.0 passes through the wrong
  route and hides the bug. Test at −20.0.
- **At minimum volume the receiver reports the literal string `--`**, not a
  number. Parse defensively.
- **`VolumeDisplay: Absolute` changes only the front panel.** `MasterVolume` is
  still relative dB; do not add 80 to it.
- **Mute is lower case when read (`on`/`off`) and upper case when written
  (`MUON`/`MUOFF`).** Compare case-insensitively.
- **Port 23 takes exactly one client.** Holding it locks out the vendor app and
  every other integration on the network. Treat a connection refusal as "someone
  else has it", not as the device being down.
- **The HTTP server serialises requests.** Firing several at once produces
  timeouts and resets that look like the device being offline. Send
  sequentially, allow seconds, retry once.
- **Surround-mode selection is a request, not a setting.** The receiver
  substitutes based on the incoming stream and reports the substitution with no
  error. Show `SurrMode`, never the value you sent.
- **The input list is per-unit.** `<InputFuncList>` is authoritative;
  `<RenameSource>` holds the user's labels, positionally alongside it. Send the
  wire token, show the rename.
- **There is no HEOS here.** HEOS Built-in arrived on the 2018 AVR-S750H and the
  X-series H models. On an AVR-S720W, TCP 1255 is closed, and a closed 1255 is
  the expected result rather than a fault.
- **Single zone.** The `Zone2`/`Zone3` documents and the `Z2`/`Z3` command
  prefixes belong to the family, not to this model.

## Security note

There is no authentication on any local surface. Network reachability *is* the
access-control model: anything that can route to port 80 or port 23 can power
the receiver on at 3 a.m. at whatever volume it likes. A consumer should say so
rather than imply a credential protects it.

## References

- [Denon AVR-S720W owner's manual](https://manuals.denon.com/AVRS720W/NA/EN/)
- [Denon support — per-model AV receiver control protocol documents](https://www.denon.com/en-us/support/)
- [denonavr — Python library (Home Assistant's backend)](https://github.com/ol-iver/denonavr)
- [Home Assistant Denon AVR Network Receivers integration](https://www.home-assistant.io/integrations/denonavr/)
- [openHAB denonmarantz binding](https://www.openhab.org/addons/bindings/denonmarantz/)
- [Unofficial AirPlay protocol specification](https://nto.github.io/AirPlay.html)
- [librespot — open Spotify Connect implementation](https://github.com/librespot-org/librespot)

Machine-readable spec: `device-specs/devices/denon-avr-s720w.yaml`.
