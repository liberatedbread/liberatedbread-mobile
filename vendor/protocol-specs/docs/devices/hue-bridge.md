# Philips Hue Bridge

> **Status**: Discovery, pairing and per-light control executable from the spec; verified against a live BSB002
> **Protocol**: WiFi (mDNS/SSDP + CLIP v1 REST over HTTPS/HTTP)
> **Manufacturer**: Signify / Philips Hue
> **Manufacturer Status**: Active (protocol closed; local API needs no account)

## Overview

The Hue Bridge is a Zigbee-to-LAN gateway: one network presence fronting a
population of lights and sensors that are the owner's, not the spec's, to
enumerate. Its local REST API (CLIP v1) survives entirely without the vendor
cloud — pairing is a physical button press, the issued credential never
expires, and every control call stays on the LAN. That makes the bridge a
model citizen for cloud-free rescue even while Signify remains in business:
the v1 round bridge (BSB001) is genuinely abandoned hardware, and every
generation — BSB001, BSB002 square, and the 2025 Bridge Pro (BSB003) —
answers the same v1 API.

Three things a client does, all executable from
`device-specs/devices/hue-bridge.yaml` alone (`scripts/test_hue_spec.py`
proves it with nothing but the standard library):

1. **Find** the bridge — mDNS `_hue._tcp`, SSDP as a fallback.
2. **Pair** — poll `POST /api` while the user presses the link button.
3. **Drive** — one `GET …/lights` enumerates every light with its state;
   `PUT …/lights/<id>/state` writes; read back after writing.

## Discovery

Primary discovery is mDNS `_hue._tcp.local.`. The TXT record carries
**`bridgeid` and `modelid` only** — no `mac`, no `apiversion`; anything else
a client wants comes from `GET /api/config`, which answers without
authentication. Current firmware advertises SRV port 443 (HTTPS primary);
2019-era firmware advertised 80. Use the advertised port.

`bridgeid` is the stable identity everything keys off — credentials, TLS
pins, scan dedupe — because the IP is just a DHCP lease. It is the Ethernet
MAC in EUI-64 clothing: `00:17:88:aa:bb:cc` becomes `001788FFFEAABBCC`
(splice `FFFE` into the middle, uppercase). The spec's Bridge Config example
satisfies that rule and the test suite checks it.

SSDP is the fallback for the BSB001/BSB002: the bridge answers the generic
`upnp:rootdevice` / `urn:schemas-upnp-org:device:Basic:1` targets, which
every router and printer also answers — so SSDP can *find* a bridge but only
the description XML (or a follow-up `GET /api/config`) can say that is what
you found. The **Bridge Pro has no SSDP at all**; mDNS is its only local
discovery. A third path, N-UPnP (`https://discovery.meethue.com/`), returns
registered bridges' LAN addresses from the cloud — documented in the spec's
notes, deliberately not something a local-first client should lean on.

```bash
python scripts/hue_discover.py --timeout 5
```

## Pairing (link button)

No account, no cloud, no expiry — the link button is a proximity proof:

1. `POST /api` with `{"devicetype":"opengreeniot#hub","generateclientkey":true}`.
2. The bridge answers HTTP 200 with the v1 array envelope either way:
   error **type 101** ("link button not pressed") means *keep polling*,
   not failure.
3. The user presses the round button; within the ~30 s window the same POST
   answers `[{"success":{"username":…,"clientkey":…}}]`.
4. Store both **keyed by bridgeid**, never by IP. The `username` goes into
   every later path; the `clientkey` is the Entertainment DTLS PSK and is
   only obtainable at creation time, which is why the spec sends
   `generateclientkey` unconditionally.

`commands.create_user` is this flow as an executable command;
`payload_formats.V1Envelope` is the envelope's parse contract, including the
error types a client must know: 101 (keep waiting), 1 (unauthorized — the
stored username is gone, re-pair), 201 (attribute not modifiable while off).

## Driving lights

The spec's `Hue Light` entity is a **template stamped out per light**
(`instances: {keyed_by: id, label_path: name}`): `GET /api/<username>/lights`
answers a JSON object keyed by light id, so enumeration and every child's
full state ride one request. Poll that — never the lights one at a time;
community rate-limit guidance is roughly ten light writes a second and far
fewer whole-bridge reads.

Writes go to `PUT /api/<username>/lights/<id>/state`:

| Command | Body | Note |
|---|---|---|
| `light_turn_on` | `{"on":true}` | |
| `light_turn_off` | `{"on":false}` | |
| `light_set_brightness` | `{"on":true,"bri":200}` | `bri` is **1–254**, and rides with `"on":true` because a bare `bri` to an off light answers error 201 |

The reply acknowledges each changed attribute
(`[{"success":{"/lights/1/state/on":true}}]`) rather than reporting state —
**read the Lights endpoint back after any write**. Honour
`state.reachable`: a bulb powered off at the wall keeps its last state with
`reachable: false`, and a live toggle drawn for it is a lie.

Color and color temperature are documented on the Set Light State endpoint
(`hue`/`sat`, `xy`, `ct` in mireds) but deliberately not bound to entity
roles yet — a `set_color` role needs multi-value parameters no consumer
resolves today.

## HTTPS and the bridge's certificate

Every current bridge serves HTTPS on 443; the Bridge Pro serves **only**
HTTPS, and Signify has announced plain-HTTP retirement on the BSB002. The
certificate is a per-device leaf whose **subject CN is the bridgeid in
lowercase hex**, issued by Signify's private bridge root CA (issuer CN
`root-bridge`) — not a public chain, so stock TLS verification fails on
every bridge by design. Verify the Hue way:

1. Check the leaf CN equals the bridgeid you expect (from mDNS TXT or
   `/api/config`).
2. Pin that leaf on first use, keyed by bridgeid.
3. Treat a later pin mismatch as a different device or an interception —
   never re-pin silently, and never fall back to plain HTTP on a pin
   failure.

Plain HTTP on port 80 remains the compatibility path for the BSB001 and
older BSB002 firmware; on it the username travels in the URL, which is the
spec's stated reason to prefer HTTPS wherever 443 answers.

## CLIP v2, sensors, groups

The spec documents where the modern API lives — `/clip/v2/resource` over
HTTPS with the `hue-application-key` header (same credential), plus the
server-sent event stream at `/eventstream/clip/v2` — and stops there: v1
covers on/off/brightness on every bridge generation, v2 needs a `headers:`
vocabulary the schema does not have yet (flagged in
[P12](../contributing/spec-evolution.md#p12)). Sensors, groups and scenes
are enumerated as endpoints; the sensor entity stays declarative because the
population is heterogeneous — each sensor type carries a different state
shape, and a guessed mapping would be worse than none.

## Security notes

Two Zigbee-side RCEs are documented in the spec's notes — CVE-2020-6007
(patched in fw 1935144040) and the Pwn2Own Cork 2025 family
CVE-2026-3555…3562 — both fixed in current firmware; keep bridges updated.
The firmware check API is public and unauthenticated
(`firmware.meethue.com/v1/checkupdate`). The API username is a long-lived
LAN secret: treat it like one, and delete unused whitelist entries.

## Machine-readable spec

`device-specs/devices/hue-bridge.yaml` — discovery, identification, pairing,
the executable `commands:` block, the instanced light entity, and a live
BSB002 probe (2026-07-16) under `evidence`. `scripts/test_hue_spec.py`
transcribes pairing, rendering, and child enumeration from the YAML alone
and diffs them against the spec's own examples.
