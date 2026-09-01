# Brava Oven

> **Status**: Research — cloud protocol documented from app decompilation; no local path known
> **Protocol**: Wi-Fi (cloud-only: HTTPS REST + socket.io "DeviceNet"); **no BLE, no LAN protocol**
> **Manufacturer**: Brava Home Inc. (acquired by Middleby Corporation, 2019)
> **Manufacturer Status**: Shutdown — ceased normal business operations effective 2026-03-06; cloud still answering as of 2026-08-18 but may be discontinued at any time

## Overview

The Brava Oven is a countertop smart oven that cooks with six infrared
lamps ("Pure Light Cooking") across three zones, watched by an internal
camera, with a wired temperature probe and a colour touchscreen instead of
knobs. It is documented here because its maker is gone and the oven is one
of the most cloud-dependent devices in this registry: **every smart
function — recipes, app control, telemetry, camera, even account linking —
is brokered by the Brava cloud, and there is no local protocol at all.**

The companion app's role turned out to be a telescope, not a remote: it
never talks to the oven directly. Both app and oven are outbound clients of
"DeviceNet", a socket.io bus at `devicenet.brava.com`, whose message
vocabulary and topic namespace are documented below and are the foundation
for any future resurrection effort.

## Hardware

| Property | Value |
|----------|-------|
| Models | Brava Oven (original, metal door), Brava Glass (glass door); "Brava Pro" in 2024-era marketing |
| Radio | Wi-Fi 2.4 GHz DTS (2412–2462 MHz, ~40 mW) + 5 GHz UNII (5180–5825 MHz); **no Bluetooth** |
| FCC ID | [2AOGABRAVAONE](https://fccid.io/2AOGABRAVAONE) ("BRAVAONE", granted 2018-10-05) |
| On-device software | Linux; a `devicenetd` daemon speaks the cloud protocol, `coreui` runs the touchscreen UI |
| Sensors | Internal cook camera, wired TempSensor probe |
| Companion app | Android `com.brava` v1.20.8 (React Native + Hermes); no Bluetooth/location permissions — it cannot provision Wi-Fi |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `device_ui` (Wi-Fi on the oven's touchscreen) + `cloud_account` (app sign-in + linking) |
| Setup AP / advertised name | None — the oven never hosts an AP and never advertises BLE |
| Passphrase protection | not_applicable (typed into the oven itself; never crosses the app) |
| Confidence | medium (app side derived from decompile; on-oven flow not replayed) |

Wi-Fi credentials are entered on the oven's own touchscreen — the app
manifest contains no Bluetooth, location, or SoftAP machinery, and no
provisioning code exists in the decompiled bundle. The app signs in with
email + one-time code (`POST /account/otp/` → `POST /auth/mobile`) and the
oven is linked to the account server-side; link/unlink is observable as
`actors_linked` / `actors_unlinked` events on DeviceNet. The exact on-oven
linking step was not recovered and needs hardware confirmation.

**Factory reset**: unknown. No reset procedure was found in the app (it
cannot reach the oven directly); a reset is presumably an on-oven menu
action clearing Wi-Fi credentials and the account link. Treat as
unestablished until someone runs it on hardware.

**Rebinding to a new network**: in place, from the oven's touchscreen Wi-Fi
settings — the old network does not need to survive, and the app is not
involved. Re-linking to an *account*, however, is cloud-mediated and stops
working when the backend does.

## Protocol Summary

There is no BLE service table and no LAN endpoint table for this device —
those sections of the template are intentionally empty. The protocol that
exists is the cloud bus.

### DeviceNet (socket.io / Engine.IO v4 over HTTPS)

Endpoint: `https://devicenet.brava.com/devicenet/socket.io/` (QA:
`qa-devicenet.brava.com`). The Engine.IO handshake was verified live on
2026-08-18:

```
GET /devicenet/socket.io/?EIO=4&transport=polling
→ 0{"sid":"...","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":5000}
```

Session: `connect()` → `hello` (`{agent, features, profile,
protocolVersion: "1.0.0", version}`; profiles `oven` / `mobile` / `web` /
`server` — the oven itself is on the bus as `oven`) → `auth` carrying the
account token; ready when an HTTP-style `code == 200` comes back.

**Message codes**: `HI` (hello), `BRAVA-TOKEN` (auth), `SUB` / `UNSUB`,
`PUB`, `TRACK`, `ACK` (`{code, topic, requestId}` — publishes wait on an
ack channel), `ERR`. Every published message carries `{id, sentAt,
sequence, sentAtDeviceEpoch}`.

**Topic namespace** (`<aid>` = the oven's actorId; `<env>` = production /
qa / local):

| Topic | Direction | Use |
|-------|-----------|-----|
| `status.request.<aid>` | app → oven | Request full status |
| `telemetry.request.<aid>` | app → oven | Request telemetry stream |
| `telemetry.data.<mode>.<rate>.<aid>` | oven → app | Telemetry (`full` / `oncepersecond` seen) |
| `camera.request.<aid>` | app → oven | Request camera feed (chunked or framed) |
| `camera.data.<aid>` | oven → app | Camera frame chunks (reassembled via `frameNumber`/`chunks`) |
| `remotecontrol.<aid>` | app → oven | **All control commands** |
| `<env>.event.oven.devicenetd.cook_started.<aid>` | event | Cook started |
| `<env>.event.oven.devicenetd.cook_completed.<aid>` | event | Cook completed |
| `<env>.event.oven.devicenetd.error_occurred.<aid>` | event | Oven error |
| `<env>.event.oven.coreui.cook_almost_complete.<aid>` | event | UI-level cook-nearly-done |
| `<env>.event.backend.auth.actors_linked.<aid>` / `..._unlinked` | event | Account↔oven linking |
| `<env>.event.backend.prefs.preference_updated.<aid>` | event | Prefs sync |
| `<env>.event.cms.publisher.custom_cook_updated.<aid>` | event | Content sync |

**Control**: everything is a `PUB` to `remotecontrol.<aid>` with
`{action, ...}`; actions are `start`, `stop`, `pause`, `step`, `reset`,
`acknowledgeStatus`, `enqueue`, `none`. Enqueue variants include
`enqueueCook` (`recipeV2Id` + variant ids), `enqueueCustomCook`,
`enqueueCombo`, `enqueuePreset`, `enqueueRecipeV3`, `enqueueManualMode`,
`enqueueMultiStep`, `enqueueCustomCookV3`. **Safety interlock**: remote
commands only *enqueue* a cook — a human must press the oven's physical
start button to begin heating.

### REST API (supporting services)

Base `https://api-94063.brava.com`: auth (`/auth/mobile`,
`/account/otp/`, `/account/auto_login/`, `/token`), recipes
(`/recipes/`, `/recipev3/`, `/publisher`), custom cooks
(`/custom_cooks/`, `/v2/custom_cook/`, `/v3/custom_cook/` — portable JSON,
shareable via `shareCode` deep links), cook history and metrics
(`/cooking/cooklog[s]/`, `/cooking/metrics/`), push registration
(`/notifier/api/link_device/`), preferences on `prefs.brava.com`, and a
cook-camera video relay on AWS API Gateway (`cookvideo-prod`, us-east-2).

### What does not exist

No mDNS advertisement, no SoftAP mode, no RFC1918 listener, no
HTTP-to-oven code anywhere in the app. The FCC grant covers Wi-Fi client
radios only. The oven is an outbound cloud client, full stop.

## Cloud Dependency & Home Assistant Guidance

**There is no Home Assistant, ESPHome, or other open-source integration for
Brava, and as of this writing none is possible** — there is no local
surface to integrate against. Anything claiming Brava support should be
treated with suspicion.

What dies with the cloud: app login, the entire recipe library (cook
programs are cloud-delivered, not stored on the oven), remote
enqueue/status/telemetry/camera, push notifications, account linking, and
firmware updates (already frozen since 2026-03-06). What plausibly
survives: manual cooking from the touchscreen — presumed, **not
hardware-verified**; April 2026 third-party reporting describes the
post-cloud Brava as "an expensive, dumb oven".

**The rescue path, and its one open gate**: the oven's `devicenetd` and the
app both reach plain TLS hostnames under `brava.com`. Re-implementing the
DeviceNet socket.io server (the full vocabulary is documented above) plus a
minimal REST/auth surface, then DNS-redirecting `devicenet.brava.com` and
`api-94063.brava.com` to it, would resurrect app control — **if** the oven
does not pin the vendor's certificate. That is unknown and is the single
most valuable experiment available: probe `devicenetd`'s TLS posture with a
DNS redirect and a self-signed cert *while the real servers are still up
for comparison*.

Second priority: **archive now**. The recipe library and custom-cook JSON
(`/recipes/`, `/v3/custom_cook/`, `/publisher`) are still being served by a
zombie cloud that the vendor says may disappear at any time; a local recipe
library is feasible because custom cooks are portable JSON. Third: capture
the oven's outbound traffic during a firmware update to learn the OTA URL
and whether images are signed — no firmware URL exists anywhere in the app,
because OTA is entirely oven-side.

Failing all software paths, the oven runs Linux (`devicenetd` + `coreui`);
serial or eMMC access would yield the client configuration, certificates,
and update URLs directly.

## Tools Used

- [x] jadx (native shell + manifest)
- [x] hbc-file-parser / hbc-decompiler (Hermes v94 bundle → pseudo-JS)
- [x] Live HTTPS probes of the vendor cloud (2026-08-18)
- [ ] Hardware capture of DeviceNet traffic (requires a linked oven)
- [ ] DNS-redirect TLS-pinning probe against the oven
- [ ] Firmware-update traffic capture / eMMC dump

## References

- [FCC filing 2AOGABRAVAONE](https://fccid.io/2AOGABRAVAONE) — Wi-Fi-only grant, no Bluetooth
- [Brava support / shutdown notice](https://support.brava.com/) — operations ceased 2026-03-06; services may be discontinued at any time
- Machine-readable spec: `device-specs/devices/brava-oven.yaml` (sources: `com.brava` v1.20.8, sha256 `884e566f…b6216`, APKPure CDN, 2026-08)

## Contributors

- @opengreeniot — app acquisition, decompilation, DeviceNet protocol recovery, live cloud probes
