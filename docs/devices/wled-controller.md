# WLED Addressable LED Controller

> **Status**: Complete (documented, not hardware-verified)
> **Protocol**: WiFi — JSON/HTTP, WebSocket, MQTT, plus realtime UDP
> **Manufacturer**: WLED project (Aircoookie and contributors)
> **Manufacturer Status**: Active
> **Openness**: `open_by_design` — published protocol, free firmware, nothing reverse engineered

## Why this one is different

Every other spec in this registry is a reconstruction. Somebody captured
traffic, decompiled an app or read flash, and wrote down what a vendor never
intended anyone outside to know. This one is not that. WLED publishes its
protocol, ships its firmware under the EUPL, and treats third-party clients as
the reason the API exists.

It is here for three reasons.

**It is the reference point.** Everything the rest of the registry works
backwards toward — a documented state object, a stable identity key, a local
control plane with no account — WLED already has. It is useful to have the
target in the same shape as the reconstructions.

**It makes the `openness` flag mean something.** A registry whose framing is
"we liberated its documentation" needs a way to say "this one did not need
liberating", or it quietly takes credit it has not earned. `openness:
open_by_design` on this spec is that statement, and it is machine-readable so
a consumer can sort the citations from the guesses.

**People arrive here holding one.** WLED controllers turn up in the same
drawers as abandoned LED signs, often as the thing somebody replaced an
abandoned controller *with*. Documenting where the boundary sits — what is
WLED and what is the vendor firmware it displaced — is useful in its own
right.

!!! note "Read upstream first"
    [kno.wled.ge](https://kno.wled.ge) is authoritative and this page is not.
    Nothing here was verified against hardware, so nothing in the spec claims
    `confirmed`. Where a constant is quoted it was read out of the named
    source file, not remembered. An open protocol is also a moving one: pin
    behaviour to the `info.vid` a device reports, not to this document.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | None — firmware, not a product |
| Chipset | ESP8266 or ESP32 |
| Radio | WiFi 802.11 b/g/n, 2.4 GHz only |
| Typical boards | Bare dev boards, QuinLED, Athom, Dig-Uno / Dig-Quad, reflashed retail controllers |

The device this spec describes is the firmware and its network surface. The
same API answers on a $3 dev board and on a purpose-built controller, which is
exactly why a client should feature-detect rather than maintain a hardware
list.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `softap_http` |
| Setup AP | `WLED-AP`, passphrase `wled1234` (compile-time default, publicly documented) |
| Portal | `http://4.3.2.1/`, with captive DNS answering every name |
| Passphrase protection | `plaintext` |
| Confidence | medium (from upstream docs; not replayed here) |

The home network passphrase is submitted as a plain HTTP form field, over an
access point whose own passphrase is a published constant. The exposure window
is short — the seconds of a form POST, within radio range — but it is real,
and a client automating provisioning should say so rather than present the
flow as secure.

**Factory reset** has three paths, and the difference between them matters:

| Path | Clears |
|------|--------|
| Hold button 0 for **>6s** | WiFi settings only — presets and effects survive |
| Hold button 0 for **>12s** | Erases flash — back to first-boot state |
| Config → Security & Updates | All custom settings data: passwords, config, macros, presets |

Export `/presets.json` before any of them. On a large install that
configuration is hours of work and there is no undo.

**Rebinding to a new network**: in place, from the settings UI, while the
device is still on the old network. If the old network is already gone, WLED
reopens `WLED-AP` when it cannot connect — unless the recovery AP has been
disabled in Security settings, in which case the button holds above are the
only way back.

## Protocol Summary

Two planes, and confusing them is the most common way a client appears broken.

```
control plane  →  JSON/HTTP · WebSocket · /win · MQTT   → sets state, runs effects
realtime plane →  E1.31 · Art-Net · DDP · TPM2 · WARLS  → streams pixels, bypasses effects
```

A controller receiving realtime data ignores its own effect engine until the
stream stops and the timeout lapses. `state.live` is true while that is
happening. **A client whose colour changes seem to do nothing should check
`state.live` first** — the usual cause is another sender still holding the
device.

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/json` | Everything: state, info, effects, palettes. Fetch once, don't poll |
| GET | `/json/state` | State alone — the correct poll target |
| POST | `/json/state` | Apply a partial state object |
| GET | `/json/info` | Read-only metadata; the endpoint that identifies a device as WLED |
| GET | `/json/si` | State + info without the static arrays |
| GET | `/json/eff` | Effect names; index is the `seg.fx` value |
| GET | `/json/pal` | Palette names; index is the `seg.pal` value |
| GET | `/json/fxdata` | Per-effect parameter metadata — which sliders each effect uses |
| GET | `/json/nodes` | Other WLED devices seen on the sync channel |
| GET | `/json/cfg` | Full configuration. **Contains credentials — never log it verbatim** |
| GET | `/presets.json` | Preset and playlist store; the backup before any reset |
| GET | `/win` | Legacy query-parameter API answering XML |
| GET | `/update` | OTA firmware upload, gated by the OTA lock passphrase |

### WebSocket

`ws://<device>/ws` pushes the same state object on change, and accepts state
objects for writes. Use it instead of polling: these are single-core
microcontrollers also driving the LED bus, and a client polling at UI framerate
degrades the animation it is displaying. Connection capacity is small, so hold
one socket per device, not one per view.

### Realtime protocols and ports

| Protocol | Port | Source of the port |
|---|---|---|
| WLED notifier / sync | 21324 | Default; read `info.udpport` — it is user-configurable |
| WARLS / DRGB / DRGBW / DNRGB | 21324 | Same channel, selected by byte 0 = 1/2/3/4 |
| E1.31 (sACN) | 5568 | `E131_DEFAULT_PORT`, `ESPAsyncE131.h` |
| Art-Net | 6454 | `ARTNET_DEFAULT_PORT`, `ESPAsyncE131.h` |
| DDP | 4048 | `DDP_DEFAULT_PORT`, `ESPAsyncE131.h` |
| TPM2.net | 65506 | Sync settings |
| Hyperion | 19446 | Upstream docs |
| UDP sound sync (v2) | 11988, multicast 239.0.0.1 | Sound-reactive builds only |

E1.31 is the interoperable choice — every console and xLights speaks it. DDP
is the efficient one for large single-controller installs, at 1440 channels per
packet. DNRGB is the one to reach for when driving a strip longer than 490
pixels over WLED's own protocol, since its start-index field is what lifts the
single-packet ceiling.

### Discovery

WLED registers **two** mDNS services on port 80, `_wled._tcp` and `_http._tcp`,
with a single TXT record, `mac`. Browse the WLED type: `_http._tcp` matches
every web server on the LAN, printers and routers included. Anything found via
the fallback must be confirmed by fetching `/json/info` and checking
`info.brand`.

Key on `info.mac`. Not on IP — these are DHCP clients on consumer routers. Not
on the user-set name either: WLED installs commonly run several controllers
named by room, and names get reused. The default hostname is `wled-` plus the
last six hex characters of the MAC, which is a display hint, never an identity.

`/json/nodes` is a cheap second discovery path — find one controller and it
names its peers, which catches devices whose mDNS the network is dropping.

### Security model

There isn't one, and that is worth stating plainly. WLED issues no per-client
credential: anything that can reach port 80 has full control, including the
settings pages, unless OTA lock is enabled. No pairing, no token, no way to
tell one client from another. Network reach *is* the security model. Treat a
WLED controller as trusting its LAN completely, and put it on a VLAN if that
matters.

## Firmware variants

| Variant | Minimum | Notes |
|---|---|---|
| WLED | 0.13.3 | Mainline |
| WLED SR (Sound Reactive) | 0.13.3 | Adds audio effects and the sound-sync channel; effect indices diverge from mainline |
| MoonModules | — | Community fork, broadly API-compatible |

Gate on `info.vid` and on the presence of a field, never on parsing
`info.ver`. Fork version strings are not ordered against mainline's and cannot
be compared numerically.

## Client applications

[WLED+](https://wledplus.com) is a cross-platform (iOS, Android, macOS) client
built, in its own description, exclusively on the JSON and WebSocket APIs — it
implements none of the realtime protocols itself, it configures the device that
does. It names WLED ≥ 0.13.3, WLED SR ≥ 0.13.3 and MoonModules as its
supported set, which is where the compatibility floor above comes from. WLED
Native is the original official app.

That an independent third-party app can be built on nothing but the documented
API, without a teardown, is the practical meaning of `open_by_design`.

## Tools Used

- Upstream documentation at [kno.wled.ge](https://kno.wled.ge)
- WLED source: `wled00/const.h`, `wled00/wled.cpp`,
  `wled00/src/dependencies/e131/ESPAsyncE131.h`

No hardware. No capture. Nothing to reverse engineer.

## References

- [WLED source](https://github.com/wled/WLED) — EUPL-1.2
- [WLED documentation](https://kno.wled.ge)
- [JSON API](https://kno.wled.ge/interfaces/json-api/)
- [UDP realtime](https://kno.wled.ge/interfaces/udp-realtime/)
- [E1.31 / Art-Net / DDP](https://kno.wled.ge/interfaces/e1.31-dmx/)
- [MQTT](https://kno.wled.ge/interfaces/mqtt/)
- [WLED+ app](https://wledplus.com)
