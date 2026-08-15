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

Target the **mainstream ESPHome ratgdo firmware** (also what Konnected's blaQ
ships). Discover via mDNS `_esphomelib._tcp` (the app's meta-query sweep already
enumerates it); read the `project_name` TXT to tell a ratgdo from any other
ESPHome device.

## Two local transports (no cloud, no broker)

**Web server (HTTP :80, enabled by default)** — simplest for a phone app:

| Action | Request |
|--------|---------|
| Door state | `GET /cover/door` → JSON (`state`, `current_operation`, `position`) |
| Open / close / stop / toggle | `POST /cover/door/{open,close,stop,toggle}` |
| Set position (Sec+ 2.0 only) | `POST /cover/door/set?position=<0..100>` |
| Light | `POST /light/light/{turn_on,turn_off,toggle}` |
| Lock remotes | `POST /lock/lock_remotes/{lock,unlock}` |
| Sensors (read) | `GET /binary_sensor/{obstruction,motion,motor,button}` |
| Live state push | `GET /events` (SSE; `state` events, same JSON) |

No auth by default. Entity ids are `slugify(name)` — the cover is `door`, not
its C++ id.

**Native API (TCP :6053, protobuf)** — always present, HA-grade, efficient;
framing `0x00` plaintext / `0x01` Noise-encrypted (PSK from `api: encryption:
key:`). Detect encryption via the mDNS `api_encryption` TXT key. Heavier to
implement than REST/SSE — prefer the web server for a first cut.

## Caveats

- **Security+ 1.0** openers have no stop/position — expose those only for
  Sec+ 2.0.
- Door commands move a heavy motorised door — treat as advanced and surface
  obstruction/state.

## References

- <https://github.com/ratgdo/esphome-ratgdo>
- <https://esphome.io/components/web_server/>
- <https://esphome.io/components/api/>
- <https://ratgdo.github.io/esphome-ratgdo/>
