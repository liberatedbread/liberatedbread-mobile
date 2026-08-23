# June Intelligent Oven

> **Status**: Research
> **Protocol**: Wi-Fi → vendor cloud only (REST + WebSocket); no LAN, no BLE control surface
> **Manufacturer**: June Life, Inc. (acquired by Weber-Stephen Products, 2021)
> **Manufacturer Status**: Shutdown — **all cloud services retire 2026-09-22**

## Overview

The June is a countertop convection oven with a 5-inch touchscreen, an interior
camera, a probe thermometer, and (on Gen 3) a cavity weight sensor. Every
connected function — remote control, camera, guided cooks, recipes — is relayed
through June's cloud. There is no local API, no mDNS/SSDP advertisement, no
AP-mode provisioning, and no BLE control surface in any known firmware.

!!! warning "Hard shutdown: 2026-09-22"
    Weber retires the June app and **all** cloud services on **2026-09-22**
    ([Weber's FAQ](https://consumer-care.weber.com/s/article/What-is-happening-to-the-June-App)).
    After that date: remote control, live camera, recipes, push notifications,
    pairing of new companions, and all software updates stop working. The oven
    keeps cooking from its own touchscreen, and on-device food recognition
    survives frozen at its last model.

    **Do not factory-reset the oven.** A new or reset oven must download
    software from the cloud on first boot; after the shutdown it cannot, and
    the oven is effectively bricked.

    **If you own one, pair it and export the pairing material now.** The
    Ed25519 seed an oven already trusts keeps working against any endpoint
    that can reach it — after 2026-09-22 that material cannot be re-minted.

The full wire protocol has nonetheless been recovered (see References), so this
page documents both the dependency and the protocol — the former so nobody buys
or keeps one uninformed, the latter because a replacement cloud is the only
rescue path and every such effort needs the wire format.

## Hardware

| Property | Value |
|----------|-------|
| Models | Gen 1 (JCP01, 2016), Gen 2, Gen 3 (JCH03 "meerkat", 2020) |
| Chipset | Gen 1/2: NVIDIA Tegra K1, 2 GB RAM, 8 GB flash. Gen 3: MediaTek MT8385, 2 GB LPDDR4, 16 GB eMMC |
| Radio | Wi-Fi. BLE hardware present on Gen 1 and Gen 3 but **unused by any known firmware** |
| Firmware | "juneOS", AOSP-derived; final release 1.24.1.34 (never published; preserved privately by a former June engineer) |
| FCC ID | Grantee 2AJGA ([fccid.io/2AJGA](https://fccid.io/2AJGA)) |

The companion app's decompiled source contains zero BLE GATT service UUIDs, and
Weber's FAQ states Bluetooth is not supported. A former June/Weber engineer
described BLE local control as R&D that was deprioritized when the line was
discontinued in 2023. **Assume no BLE surface exists** — the one cheap open
experiment is to BLE-scan a powered oven and publish the result, whichever way
it falls. ADB and terminal access are removed from the shipped user-mode
firmware.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `device_ui` (Wi-Fi entered on the oven's touchscreen) + `cloud_account` (PIN pairing) |
| Setup AP / advertised name | None — there is no SoftAP, BLE or WPS provisioning path |
| Passphrase protection | not_applicable (credentials never leave the touchscreen) |
| Confidence | high (documented in a clean-room spec executed against a real oven; not replayed by us) |

Pairing a companion runs through the cloud:

1. The client registers itself: `POST /2/devices/register` with a random
   `device_id`, a random 32-hex password, and the app's published protocol
   constants → 7-day Bearer token.
2. The client requests an 8-digit PIN (final digit is a Damm check digit) and
   the user types it on the oven.
3. The client acts as the **SRP-6a server** (roles are inverted; the oven is
   the client): RFC 5054 8192-bit group, g=19, SHA-1, identity `"user"`,
   password = the displayed PIN. It POSTs `{salt, B, companion_info}` to
   `/2/devices/pairing/{code}/companion`, where `companion_info` is sealed with
   a NaCl secretbox under `K = BLAKE2b-256(S)`.
4. **Do not DELETE the pairing session early** — the oven has not finished SRP
   yet and will emit `10027 PairingSessionInvalidated`. Wait for the second
   `10026` frame carrying `oven_info`.
5. `GET /2/devices/{deviceId}/associated` returns the `oven_id`.

Persist — and export — `oven_id`, `device_id`, the device password and the
Ed25519 seed. All of it becomes un-mintable on 2026-09-22.

**Factory reset**: the on-screen procedure is not documented in our sources,
but the *consequence* is: a reset oven must complete a cloud software download
on first boot, which is impossible after the shutdown. Treat factory reset as
un-brickable only if a captured firmware image or replacement cloud exists.

**Rebinding to a new network**: in place, from the touchscreen — no reset and
no cloud involvement needed for the network join itself.

## Protocol Summary

Cloud REST + a signed JSON-over-WebSocket command channel. No BLE services, no
local HTTP endpoints — those tables are empty by design, not by omission.

### Hosts

| Role | Production |
|------|-----------|
| REST | `https://api.junelife.com` (`/2/…`) |
| Messaging REST + WebSocket | `https://messaging.junelife.com`, `wss://messaging.junelife.com/1/messaging/websocket/companion` |
| Recipes | `https://recipes.junelife.com` (never captured) |
| OTA | `https://devices-ota.walker-cloud.com`, legacy `dev-devices-ota.junelife.com` |

Each junelife host has a `dev-` staging twin. All hosts answered TLS/HTTP when
probed 2026-08-18, and the TLS wildcard was renewed to 2027-01-31 — the only
cliff is the announced shutdown.

### Frame format

Compact JSON with **exact key order**: `v, message_code, order, time,
signature, device_name, device_id, data, target`. The signature is 72 bytes —
`base64(BLAKE2b(pubkey, 8) ‖ Ed25519_sign(canonical_json))`, computed with the
signature field empty. **A wrong signature is silently dropped**: no ack, no
error, so clients must bound the wait with a timeout. Temperatures are integer
milli-degrees Celsius (350 °F = `176667`); durations are milliseconds.

### Message codes (selected)

| Dir | Code | Meaning |
|-----|------|---------|
| → | 11002 | Preheat / start cook (`primitive_type`, `temperature_cavity` in milli-°C) |
| → | 11004 | Cancel cooking |
| → | 11005 | Set cavity target (rejected mid-cook — cancel and restart instead) |
| → | 11006 | Set timer (ms) |
| → | 11011 | Ping / keepalive (~7 s) |
| ← | 10020 | Ack — `success` / `not-allowed` / `door-open` / `not-ready` / `cleaning` |
| ← | 10018 | Device state — `idle` / `active` |
| ← | 10013 | Telemetry ~1 Hz — cavity temp, probe array, Gen 3 weight, progress |
| ← | 10011 | Camera frame — ~1 fps JPEG stills via short-lived signed URLs, never video |
| ← | 10026 / 10027 | Pairing info / pairing session invalidated |

The full code table (including guided-cook and recipe codes) is in
`device-specs/devices/june-oven.yaml`. The `10020` ack vocabulary is the
protocol's own safety channel — surface it verbatim, never collapse it into
"failed". June's remote-preheat disable and 30-minute no-food auto-off (added
after 2019 self-preheating incidents) live on the oven; no client should offer
a way around them.

### Conformance without hardware

`mvanhorn/printing-press-library` ships byte-exact synthetic vectors for the
signature, SRP-6a, the Damm check digit and the secretbox seal
(`internal/june/testdata/vectors.json`). An implementation that agrees with
those vectors byte-for-byte is wire-compatible — no oven and no network needed.

## Cloud dependency and Home Assistant keep-alive

Existing integrations (`keithah/homebridge-june-oven` and the HA integrations
built on it) are **cloud clients**: they talk to June's servers, not to the
oven. When the servers shut down on 2026-09-22 they stop working — the plugin
author's own words are that it "is toast" then.

Practical guidance for HA users:

- **Before 2026-09-22**: pair while pairing still works and **export your
  pairing material** (`oven_id`, `device_id`, device password, Ed25519 seed).
  Do not factory-reset the oven. If you can put the oven behind a gateway you
  control, capture 24 hours of its traffic (DNS, SNI, NTP) — the DNS query log
  is the only known way to name the oven's real update host, and this is the
  one experiment that dies with the cloud.
- **After 2026-09-22**: the oven remains a perfectly good touchscreen oven.
  Home Assistant control would require a **replacement cloud** reached by
  DNS-redirecting the junelife hosts (a bench gateway answers DNS itself, so
  this does not race the shutdown). Two gates are unmeasured: whether the oven
  pins TLS, and where it gets its clock — Weber's FAQ says the clock is
  cloud-dependent, so a replacement cloud may need to answer NTP too.
- One unverified community report claims an open TCP **8156** on the oven's LAN
  interface. If you own an oven, `nmap -sV` settles it; publish the result
  either way.

## Tools Used

- [x] jadx — decompile of `com.junelife.companion` 1.24.1.11 (final) and `com.weber.connect`
- [x] Live host probes (DNS/TLS/HTTP) of all junelife and OTA hosts, 2026-08-18
- [ ] Passive capture of oven traffic behind a controlled gateway (deadline-bound)
- [ ] BLE scan of a powered oven; `nmap -sV` for the port-8156 question

## References

- [keithah/homebridge-june-oven](https://github.com/keithah/homebridge-june-oven) — clean-room protocol spec + working clients, verified against a real Gen 3 oven
- [mvanhorn/printing-press-library](https://github.com/mvanhorn/printing-press-library) — byte-exact conformance vectors (the test oracle)
- [Weber FAQ — June app shutdown](https://consumer-care.weber.com/s/article/What-is-happening-to-the-June-App)
- [FCC grantee 2AJGA](https://fccid.io/2AJGA)
- [Owner thread: reset ovens brick after 2026-09-22](https://www.reddit.com/r/Juneoven/comments/1v75wr7/new_and_reset_ovens_will_be_bricks_after_922/)

## Contributors

- Liberated Bread research — re-acquisition, hashing and jadx spot-verification
  of the final companion app (2026-08-18); OTA service recovery from the sibling
  Weber app; live host probes
- keithah — clean-room protocol spec and reference implementation (third-party,
  hardware-verified)
- mvanhorn — synthetic conformance vectors
