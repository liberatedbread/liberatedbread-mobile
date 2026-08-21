# June Oven support — app-side execution plan

Status: **plan, not yet executed**. Written 2026-08-07.

Companion document: `liberatedbread-protocol-specs/JUNE_OVEN_PLAN.md` (scope,
sequencing, guardrails) and `.../targets/june-oven.md` (evidence, protocol
constants). **Read the protocol constants from there** — this file does not
restate them, and there must be exactly one authoritative copy.

Branch: `claude/june-oven-support-plan-mk9kwr`.

---

## 1. Why this is not a spec drop

Everything the app supports today arrives the same way: a BLE scan produces an
advertisement, `matchedDeviceSpecProvider` ranks YAML specs against its name and
service UUIDs, and the Rust core turns the winning spec into typed controls. New
device, new YAML, no Dart or Rust changes. That pipeline is the app's central
idea and it is a good one.

**June fits none of it.** Three independent breaks:

1. **No local presence.** June has no BLE advertisement, no mDNS record, no LAN
   API, no AP-mode SSID. There is nothing to scan for. Discovery is an 8-digit
   PIN the owner types into the oven's own touchscreen.

   Worth knowing, because it is the obvious hope for a BLE app: Gen 1 and Gen 3
   ovens *do* carry Bluetooth radios, and a former June engineer confirms there
   was R&D toward local BLE control — as a side effect of unifying the oven with
   Weber's grill software stack. It was deprioritized in 2023 and there is no
   evidence it ever shipped in firmware. Treat BLE as closed;
   `protocol-specs/targets/june-oven.md` § "Bluetooth: intended, never shipped"
   carries the sourcing. The one thing worth doing is a five-minute BLE scan
   next to a powered oven with this app — nobody has published that result for
   any generation — and then moving on regardless of the answer.
2. **No transport.** `BleService` is the only device transport in the app.
   June needs HTTPS + a long-lived authenticated WebSocket. The `http` package
   is present but wired only to Home Assistant.
3. **No crypto, anywhere.** The Rust core's entire dependency list is
   `flutter_rust_bridge`, `serde`, `indexmap`, `serde_yaml`, `thiserror`,
   `anyhow`. June needs Ed25519, BLAKE2b with a non-default digest length,
   XSalsa20-Poly1305 secretbox, SHA-1, and 8192-bit modular exponentiation for
   SRP-6a. None of that exists in the tree today.

So this is a new subsystem sitting *beside* the spec pipeline, not inside it.
Say so in the design rather than trying to bend the spec loader into a shape it
was not built for. The YAML spec in the other repo still gets written — it
documents the protocol and records the cloud dependency — but the app will not
*drive* June from it. Precedent for that split already exists: `protocol_handler`
names a consumer-side handler "for protocols that cannot be fully expressed in
YAML", and `crate::protocol::daniao` is the first one. June is the second, and
much larger.

The app's own self-description ("A BLE companion app…" in `pubspec.yaml`, the
README's opening) stops being accurate the moment this lands. Update it in the
same PR; do not let it drift.

---

## 2. Architecture

### 2.1 The split: crypto in Rust, sockets in Dart

Follow the division the README already states — *"Rust handles protocol logic;
Flutter handles the UI, BLE transport, and permissions."*

**Rust (`rust/src/protocol/june/`)** — everything byte-exact:

- Canonical envelope construction. The signature is computed over compact JSON
  in **exact key order** (`v, message_code, order, time, signature, device_name,
  device_id, data, target`), and the oven **silently drops** any frame whose
  bytes do not match. A `#[derive(Serialize)]` struct with fields in that order
  makes the ordering a compile-time property instead of a runtime hope. Doing
  this in Dart means depending on `Map` insertion order surviving every future
  refactor — a real bug waiting to happen, with no error message when it fires.
- The 72-byte signature: `BLAKE2b(pubkey, digest_size=8) ‖ Ed25519_sign(...)`.
  Note the 8 is an *output length*, not a truncation — get this wrong and
  everything silently fails.
- SRP-6a (8192-bit group, g=19, SHA-1, `I="user"`), the Damm check digit,
  `K = BLAKE2b-256(S)`, secretbox sealing of `companion_info`.
- Milli-°C conversion.
- Frame *decoding* for the inbound codes (10011/10013/10018/10020/10014–10017/
  10026/10027) into typed DTOs.

**Dart (`lib/services/june/`)** — everything I/O:

- `package:http` for the REST calls, `package:web_socket_channel` for the
  command channel, with `perMessageDeflate` **off**.
- Reconnect/backoff, the ~7 s `11011` keepalive, `order` → `request_order`
  correlation with a timeout (a bad signature yields *no* response at all, so
  "no ack" is a real terminal state and must not hang).
- Credential storage in `flutter_secure_storage` — the same treatment the HA
  token already gets. An Ed25519 seed is a key that can start a heat cycle;
  it does not go in `SharedPreferences`.

The decisive practical benefit: **the entire Rust layer is testable against
`vectors.json` in CI with no oven, no network, and no emulator.** That is where
all the subtle failure modes live, and it is the part that can be finished and
proven before anyone touches a physical oven.

### 2.2 Endpoint configuration — the one thing that cannot be deferred

Base URLs are **configuration from the first commit**, never constants:

```dart
class JuneEndpoints {
  final Uri apiBase;        // default https://api.junelife.com
  final Uri messagingBase;  // default https://messaging.junelife.com
  final Uri wsUrl;          // default wss://messaging.junelife.com/1/messaging/websocket/companion
}
```

June's cloud dies 2026-09-22. A build with hardcoded hosts is dead on that date
and cannot be revived without a release. A build with an override survives to
talk to whatever replacement cloud the community stands up. This costs one class
now and is painful to retrofit later, so it goes in first, not last.

Consequences to honour throughout:

- **No hostname allowlists.** The upstream Homebridge plugin has exactly this
  bug — `src/protocol-decode.ts:13` hardcodes `CAMERA_HOSTS` and would reject
  camera frames from a replacement cloud. Validate the *scheme* (require HTTPS)
  and let the host be whatever the user configured.
- Expose the override in settings, alongside the existing HA settings screen.
- Do not add a custom-CA trust option in v1. A replacement cloud may need one,
  but shipping "trust this arbitrary certificate" ahead of an actual need is a
  security hole in exchange for a hypothetical. Revisit when junecloud exists.

### 2.3 Where June devices live in the app

`SavedDeviceStore` and `IoTDevice` are BLE-shaped (`deviceId` is a BLE address).
Do not overload them. Add a distinct saved-device kind for cloud-paired devices
keyed by `oven_id`, and a separate entry point — "Add a cloud device" — on the
scan screen, since a radar scanner animation cannot find something that has no
radio presence.

---

## 3. Milestones

Each is independently shippable. **M1 and M2 are the ones with a deadline**, for
the reason in §4.

### M0 — Rust protocol core, green against `vectors.json`

*No oven, no network, no deadline.*

Add to `rust/Cargo.toml`: `ed25519-dalek`, `blake2`, `crypto_secretbox` (or
`xsalsa20poly1305`), `sha1`, `num-bigint` (SRP modPow), `serde_json`, `base64`,
`hex`, `rand`, `zeroize`.

Watch the binary-size budget: `[profile.release]` is deliberately tuned for size
(`opt-level = "z"`, thin LTO, one codegen unit) because the library rides in
every APK. Measure the delta and record it in the PR. Prefer `num-bigint` over
pulling in a full bignum/crypto framework; avoid anything that drags in a TLS
stack, since TLS lives on the Dart side.

Deliverables:
- Canonical envelope + 72-byte signature, verified byte-exact against the
  `11011` keepalive and `11002` preheat vectors.
- SRP-6a server role verified against the worked exchange (salt, verifier, B, u,
  S, `K = BLAKE2b-256(S)`).
- Damm check digit and secretbox framing verified against their vectors.
- Milli-°C round-trip tests (350 °F = 176667).
- FFI DTOs for the inbound message codes.

**Acceptance: every vector reproduces byte-for-byte.** That is the whole gate.
Anything less and the oven will silently ignore us with no diagnostic.

Vendor `vectors.json` under `rust/tests/` with its provenance and license
recorded, the way `vendor/protocol-specs` already is. It contains only
deterministic synthetic values — no real credentials — which is exactly why it
is safe to commit and why nothing else about this device should be.

### M1 — Pairing and credential export

*Depends on M0. **Deadline 2026-09-22.***

- `POST /2/devices/register` → 7-day Bearer token; re-register the same
  `device_id` to refresh (the OAuth refresh grant is rejected by the server).
- `POST /2/devices/pairing` → PIN. Display the full 8-digit code **including**
  the Damm digit; that is what the user types and what SRP uses.
- Act as SRP-6a *server*; receive the oven's `A` in a `10026`; seal
  `companion_info`; `POST /2/devices/pairing/{code}/companion`.
- **Do not `DELETE` the pairing session early.** The oven has not finished SRP
  yet; deleting aborts it and yields `10027 PairingSessionInvalidated`. Wait for
  the second `10026` carrying `oven_info`, then `GET
  /2/devices/{deviceId}/associated` for the `oven_id`.
- Persist `oven_id`, `device_id`, `device_name`, `password`, `ed25519_seed_hex`
  in secure storage.
- **Export those five fields as JSON.** This is the highest-value-per-line
  feature in the whole plan: it is the exact set every other client needs
  (Homebridge, Home Assistant, the Go CLI, any future replacement-cloud client),
  and after 2026-09-22 it cannot be re-minted, because minting a PIN requires
  June's cloud. Ship it in M1, not M4.

Tell the user, once and factually, at pairing time: pairing runs through June's
servers and stops working 2026-09-22; keep the export; and do not factory-reset
the oven, because first boot requires a cloud software update that will not be
there. State it and move on — no repetition, no alarm.

### M2 — Control and telemetry

*Depends on M1. **Deadline 2026-09-22** for validation against a live oven.*

- `GET /1/messaging/device/{ovenId}/status` snapshot.
- WSS channel: connect, `11011` on open and every ~7 s, `perMessageDeflate` off.
- Commands: `11002` preheat, `11004` cancel, `11006` timer, `11005` target
  change. Note the verified limitation — a running cook's target cannot be
  retargeted; both `11005` and a re-issued `11002` are rejected. The working
  pattern is cancel-then-restart, and the UI should do that explicitly rather
  than pretending the change was applied.
- Live state from `10018` and `10013` (cavity temp, probe array, progress).
  Probe presence is **structural**: a non-empty `sensor_data.probe` array. There
  is no `food_present` field; do not invent one.
- **Surface `10020` statuses verbatim.** `door-open`, `not-ready`, `cleaning`
  and `not-allowed` are the protocol's own safety channel. "Can't start — the
  door is open" is the correct message; "Command failed" throws away the one
  piece of information the oven bothered to send.
- Only `bake` and `roast` are confirmed on-oven. Offer those; if you expose
  more `primitive_type` values, label them unverified.

Flag the cook commands `advanced` in the UI sense that
`protocol-specs/docs/CLEANROOM_RULES.md` describes — a deliberate confirmation
with a concrete reason, not a hidden feature and not a nag. The reason to state:
this starts a heating element in a room you may not be in.

### M3 — Camera

*Depends on M2. Lowest priority.*

`10011` frames carry `image_url` / `signed_url` expiring in ~300 s, ~1 fps
stills, never video. Fetch over HTTPS. Do **not** hardcode a host allowlist
(§2.2). Cheerfully skippable if time runs short.

### M4 — Home Assistant forwarding

*Depends on M2. No deadline.*

The HA sensor forwarder already exists and is BLE-fed. Cavity temperature, probe
temperatures, state and progress are natural HA sensors. This is a small amount
of work once M2 lands, and it is the piece that makes the oven useful inside a
setup the owner already runs.

---

## 4. Sequencing, honestly

Only M1 and M2 have a real deadline, and only because 2026-09-22 is when
validation against a live system becomes impossible forever. M0 has none — it is
proven against static vectors. M3 and M4 have none.

That inverts the intuitive order. **Do M0 properly rather than fast**, because
every failure mode downstream of it is silent: a wrong signature produces no ack,
no error, and no log line. Rushing M0 to "save time" for M1 buys a week of
debugging an oven that ignores you for reasons the protocol will never explain.

If the whole plan slips, the ordered fallback is:

1. M0 alone — a verified Rust implementation of the protocol, in CI, permanently
   useful to anyone building a client. Real value, no deadline, no hardware.
2. M0 + M1 — owners can bank pairing material before it becomes unmintable.
3. Everything else.

Do not start M2 before M1's export flow works. The export is the part with an
expiry date on its value.

---

## 5. Testing

- **Rust unit tests against `vectors.json`** — the primary gate. Runs in CI on
  every commit, needs nothing.
- **Dart unit tests** with a fake WebSocket: ack correlation, the no-ack timeout,
  keepalive cadence, reconnect/backoff, token refresh on 401.
- **`MockBleService` has an analogue here.** Add a `MockJuneService` replaying a
  recorded frame sequence so the UI is developable with no oven and no network,
  the way mock mode already works for BLE.
- **Platform config tests** (`test/platform/`) — if any new permission or
  entitlement is needed, pin it there like the existing 35+ tests do.
- **Never commit a real credential in a fixture.** Not a token, not an
  `oven_id`, not a seed. `vectors.json` is synthetic precisely so this is easy.

## 6. Upstream contribution

One small PR worth sending regardless of how far this plan gets:
`keithah/homebridge-june-oven` `src/protocol-decode.ts:13` hardcodes
`CAMERA_HOSTS`, which will reject camera frames from any replacement cloud even
though the rest of that plugin already supports `baseUrl`/`wsUrl` overrides. It
is a few lines and it unblocks every Homebridge user in the post-shutdown world.

That repository is also the source of every protocol fact we are building on.
Credit it in the spec, the device page, and the code.
