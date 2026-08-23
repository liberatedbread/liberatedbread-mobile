# ESPHome Node (generic)

> **Status**: Complete (written from ESPHome's own docs and source; untested here)
> **Protocol**: WiFi — ESPHome web server REST/SSE (:80) and native API (:6053)
> **Manufacturer**: Various — [ESPHome](https://esphome.io) open-source firmware
> **Manufacturer Status**: Active — local by construction, no cloud, no broker

## Overview

ESPHome is open-source firmware that turns an ESP32/ESP8266/RP2040/nRF52 board
into a locally-controlled device. It is a **platform, not a product**: a node
can be a thermometer, a plug, a bluetooth proxy, a presence sensor, a sprinkler
valve, a garage-door controller, or something its owner built on a breadboard
last weekend. Every one of them advertises the same mDNS service type and
speaks the same two APIs.

That is why this spec exists. `_esphomelib._tcp` identifies the *firmware*, so
a consumer that maps a service type to a device spec labels every ESPHome node
with whichever product spec claimed the service type first — which is exactly
what happened here while [ratgdo](ratgdo.md) was the only claimant, and every
ESPHome node on the LAN turned up as a garage-door opener.

The fix has two halves:

- Product specs on this platform carry a **`mdns_txt_match` on the
  `project_name` TXT record**. `ratgdo.` is a ratgdo; nothing else is.
- This spec is the deliberate catch-all, marked `platform_fallback: true` on
  the `_esphomelib._tcp` method. A node matching no product spec renders as
  **itself** — its own name, its own entities.

The catch-all flag is set on that method **only**. The `_http._tcp` method
below is narrowed by a TXT condition and nothing else: `_http._tcp` belongs to
every web server on the link, and being its fallback would rebuild this bug
with printers and routers in it.

### Why `integration: identify_only`

Control here is entirely possible — that is what `local_access: native` says —
but `integration` records what a consumer of this registry *does* today, and
for an unrecognised node that is: name it, show it, link to its web UI. Two
things hold that line. The spec declares no `entities` and cannot, so a
consumer has controls only once it implements runtime enumeration; and the
HTTP surface is **optional** (`web_server:` is a build choice — plenty of nodes
run `api:` alone and answer nothing on :80), so the REST grammar below is for a
client that has already found one, not a promise every node has it. When a
consumer implements enumeration over either API, this becomes `supported` with
no other change to the spec.

## Telling one node from another

ESPHome publishes a rich TXT set on `_esphomelib._tcp`:

| TXT key | Says |
|---|---|
| `mac` | Board MAC — the stable identity key. Survives rename, reflash, DHCP move |
| `friendly_name` | Human name (absent when the config sets none) |
| `project_name` / `project_version` | Present only when the firmware sets `esphome: project:` — **this is what names a product** (`ratgdo.v25iboard_secplus2`) |
| `version` | ESPHome version the firmware was built with |
| `board`, `platform` | Hardware (`d1_mini`, `ESP32`) — says nothing about function |
| `network` | `wifi` / `ethernet` / `thread` |
| `config_hash` | Changes on every config change — never an identity key |
| `api_encryption` | Native API requires Noise with a PSK |
| `api_encryption_supported` | Build can do Noise, no key set yet, plaintext still accepted |
| `api_provisioning=zero-psk` | A key may be provisioned over a zero-PSK Noise connection |

A node built without the native API publishes `_http._tcp` instead, carrying
`version`/`mac`/`config_hash`. Two build shapes land there: one with
`web_server:` (port 80 answers) and one with **neither** `api:` nor
`web_server:`, which ESPHome still advertises so `.local` resolution works at
all — and on that one nothing is listening on 80. A match on that service means
"an ESPHome node is at this address", not "there is an HTTP surface here".

## The two local APIs

**Web server (HTTP :80)** — present only when the build includes
`web_server:`, so a node that answers nothing there is normal, not broken.

| Action | Request |
|--------|---------|
| Enumerate + subscribe | `GET /events` (SSE — every entity's state on connect, then updates) |
| Entity state | `GET /<domain>/<entity>` (add `?detail=all` for name/device/select options) |
| Entity action | `POST /<domain>/<entity>/<action>[?params]` |
| Sub-device entity | `GET /<domain>/<device>/<entity>`, `POST /<domain>/<device>/<entity>/<action>` |

**Native API (TCP :6053, protobuf)** — what Home Assistant uses. Frames are
length-delimited protobuf behind an indicator byte: `0x00` plaintext, `0x01`
Noise (`Noise_NNpsk0_25519_ChaChaPoly_SHA256`, prologue `NoiseAPIInit`, 32-byte
base64 PSK). `Hello → Connect → DeviceInfo → ListEntities → SubscribeStates`.
The legacy `api: password:` was removed in ESPHome 2026.1.0.

## Enumeration is the whole trick

There is no "list entities" URL. Connect to `/events`: the node sends one
`state` event **per entity** on connect, then keeps the connection open for
updates. The domain gives you the control type and the entity's name is the
label — the entity list *is* the device. Never infer a device type from the
product name, the board, or the icon.

## Addressing changed — handle both

| Firmware | URL segment | State `id` |
|---|---|---|
| ESPHome ≤ 2025.12 | slugified `object_id` (`/sensor/outside_temp`) | `sensor-outside_temp` |
| 2026.1.0 – 2026.6 | name first, `object_id` still accepted (deprecated) | legacy `id` (+ `name_id` from 2026.1.3) |
| 2026.7 | **name only** (`/sensor/Outside%20Temp`) | still legacy `id` + `name_id` |
| ≥ 2026.8 | name only | `sensor/Outside Temp`, no `name_id` |

The two boundaries are **one release apart**, which is the trap: on 2026.7 the
URL is already name-only while `id` still carries the legacy form, so a client
that derives its URL from `id` breaks on exactly that release. Read `name_id`
first.

The robust client does not derive the identifier: read `name_id` if present,
else `id`, from the `/events` payload and send back the form the node handed
you. An identifier containing `/` is the new form. A wrong identifier answers
404 — never a silent no-op — so trying and falling back is also safe.

## Caveats

- **The web server has no auth by default**, and where the web-OTA platform is
  enabled anyone who can reach the node can flash it. Upstream says so too.
- Cross-origin browser requests to entity endpoints are rejected unless the
  origin matches or is allow-listed.
- **A generic client cannot know what a control does.** `switch/Pump`,
  `cover/Gate` and `light/Desk` render identically. Treat `cover`, `lock`,
  `valve`, `alarm_control_panel` and `climate` actions as advanced: confirm
  first, show reported state, and keep them out of bulk actions.
- Cover position is `0.0`–`1.0`, **not** a percentage. Sending `50` for "half
  open" drives the cover fully open.

## References

- <https://esphome.io/web-api/>
- <https://esphome.io/components/web_server/>
- <https://esphome.io/components/api/>
- <https://esphome.io/components/mdns/>
- <https://esphome.io/components/captive_portal/>
- <https://github.com/esphome/esphome>
