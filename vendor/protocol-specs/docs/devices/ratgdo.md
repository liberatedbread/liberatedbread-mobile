# ratgdo Garage-Door Controller (ESPHome)

> **Status**: Complete (documented from authoritative ESPHome config; hardware on order)
> **Protocol**: WiFi — ESPHome web server REST/SSE (:80) or native API (:6053)
> **Manufacturer**: ratgdo (open hardware) / Konnected (blaQ)
> **Manufacturer Status**: Active — fully local, no cloud, no broker

## Overview

ratgdo is an ESP board wired to a Chamberlain/LiftMaster opener's wall-control
terminals; it speaks the opener's Security+ 1.0/2.0 protocol (see the
[Security+ opener spec](chamberlain-garage-opener-secplus.md)) and exposes
**local, cloud-free** garage control on the network. This is the
network-facing counterpart to the wired Security+ protocol.

Target the **mainstream ESPHome ratgdo firmware**. Discover via mDNS
`_esphomelib._tcp` (the app's meta-query sweep already enumerates it) — but that
service type is the **ESPHome platform**, not this product, so the spec narrows
it with an `mdns_txt_match` on the `project_name` TXT record: every published
ratgdo board config sets it to `ratgdo.<board>` (`ratgdo.v25iboard_secplus2`,
`ratgdo.v32board_secplus2`, `ratgdo.v2board_esp8266_d1_mini_lite`). A node that
does not match is some other [ESPHome node](esphome-device.md), and rendering it
as a garage door is the bug that matcher exists to prevent. Konnected's blaQ is ratgdo-compatible
hardware: flashed with mainstream ratgdo firmware it matches like any other
board, but Konnected's own build sets its own `project_name`, unobserved here —
so a blaQ on stock firmware falls to the generic ESPHome spec until somebody
dumps its TXT records.

## Two local transports (no cloud, no broker)

**Web server (HTTP :80, enabled by default)** — simplest for a phone app:

| Action | Request |
|--------|---------|
| Door state | `GET /cover/Door` → JSON (`state`, `current_operation`, `position`) |
| Open / close / stop / toggle | `POST /cover/Door/{open,close,stop,toggle}` |
| Set position (Sec+ 2.0 only) | `POST /cover/Door/set?position=<0.0..1.0>` |
| Light | `POST /light/Light/{turn_on,turn_off,toggle}` |
| Lock remotes | `POST /lock/Lock%20remotes/{lock,unlock}` |
| Sensors (read) | `GET /binary_sensor/{Obstruction,Motion,Motor,Button}` |
| Live state push | `GET /events` (SSE; `state` events, same JSON) |

No auth by default. `position` is ESPHome's cover scale — **0.0 closed, 1.0
open, not a percentage**; sending `50` drives the door fully open.

**Which identifier goes in the URL depends on the firmware**, and ESPHome
changed it:

| Firmware | Path | State `id` |
|---|---|---|
| ESPHome ≤ 2025.12 | slugified object_id — `/cover/door` | `cover-door` |
| 2026.1.0 – 2026.6 | name first, object_id still accepted | legacy `id` (+ `name_id` from 2026.1.3) |
| 2026.7 | name only — `/cover/Door` | still legacy `id` + `name_id` |
| ≥ 2026.8 | name only — `/cover/Door` | `cover/Door`, no `name_id` |

Each command in the spec states the name form as `path` and the legacy form as
`path_fallback` (entities likewise carry `state_topic` / `state_topic_fallback`),
so an older board stays drivable from the file: send `path`, and on a **404** —
never on a timeout — send the fallback. A client that would rather not probe
reads the identifier out of `/events` instead. See
[ESPHome Node (generic)](esphome-device.md) for the platform-wide rules.

**Native API (TCP :6053, protobuf)** — always present, HA-grade, efficient;
framing `0x00` plaintext / `0x01` Noise-encrypted (PSK from `api: encryption:
key:`). Detect encryption via the mDNS TXT: `api_encryption` means a PSK is set
and Noise is required, `api_encryption_supported` means the build can do Noise
but has no key and still accepts plaintext. The legacy `api: password:` was
removed in ESPHome 2026.1.0. Heavier to implement than REST/SSE — prefer the web
server for a first cut.

## Caveats

- **Security+ 1.0** openers have no stop/position — expose those only for
  Sec+ 2.0.
- Door commands move a heavy motorised door — treat as advanced and surface
  obstruction/state.

## References

- [ESPHome Node (generic)](esphome-device.md) — the platform this rides on
- <https://github.com/ratgdo/esphome-ratgdo>
- <https://esphome.io/web-api/>
- <https://esphome.io/components/web_server/>
- <https://esphome.io/components/api/>
- <https://ratgdo.github.io/esphome-ratgdo/>
