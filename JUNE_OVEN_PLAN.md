# June Oven support — execution plan

Status: **plan, not yet executed**. Written 2026-08-07. Spans two repos:
`liberatedbread-protocol-specs` (this one) and `liberatedbread-mobile`.

The June cloud dies **2026-09-22** — 46 days from this document. That date shapes
the sequencing but does not make the work pointless; see §1.3.

---

## 1. What we are actually building

### 1.1 The ask, scoped

"Add June oven support to Liberated Bread" decomposes into two deliverables that
have very different costs and very different lifespans:

| # | Deliverable | Repo | Cost | Survives 2026-09-22? |
|---|---|---|---|---|
| D1 | A device spec + device page recording the protocol and the cloud dependency | protocol-specs | ~2 days, no hardware | Yes — it is a document |
| D2 | The app acting as a June **companion**: PIN pairing, signed command channel, live telemetry | mobile | ~3–4 weeks, first-of-kind work | Only if pointed at a replacement cloud (§1.3) |

D1 is unconditionally worth doing and should ship first. D2 is a genuine
architecture change to the mobile app and is described in
`liberatedbread-mobile/JUNE_OVEN_PLAN.md`.

### 1.2 What we are *not* building

The attached Kimi research report scopes a ~28 person-week project to build
**"junecloud"** — a full replacement for `api.junelife.com` and
`messaging.junelife.com`, including OTA/provisioning so factory-reset ovens do
not brick. That report is good work and its findings are load-bearing here, but
**building junecloud is out of scope for Liberated Bread.** Liberated Bread is a
companion app and a protocol registry; it is not a hosting project, and the
oven-side unknowns (does the oven pin TLS?) can only be resolved by someone with
a physical oven on a bench.

The right division of labour: **we build the companion, someone else builds the
cloud.** Our single hard requirement on that future is that our client must be
repointable at a different base URL — which costs nearly nothing if designed in
from the first commit, and is expensive to retrofit. That is the one decision in
this plan that must not be deferred.

### 1.3 Why D2 is still worth doing with 46 days on the clock

Three reasons, in descending order of strength:

1. **The client is the durable artifact, not the session.** Every replacement-cloud
   effort will need clients. Homebridge and Home Assistant integrations exist;
   there is no mobile one. If junecloud ships in October, a repointable Liberated
   Bread build is immediately useful and required no new protocol work.
2. **Pairing material must be captured before the cloud dies.** Pairing runs
   through June's cloud (`POST /2/devices/pairing`). After 2026-09-22 no oven can
   be paired to a *new* companion until a replacement cloud exists — but an
   Ed25519 seed the oven already trusts keeps working against any endpoint that
   can reach the oven. Every day the app can pair is a day owners can bank a key.
   This should be said plainly in the UI (§4.3).
3. Forty-six days of working remote control is not nothing for owners who have
   none otherwise.

If the executing agent judges D2 too large, **D1 plus the export flow in §4.3 is
a coherent, honest half** and should be shipped as such rather than half-building
D2.

---

## 2. Sources, and what to trust in them

| Source | What it is | Trust |
|---|---|---|
| `keithah/homebridge-june-oven`, `docs/reference/JUNE_INTEGRATION_SPEC.md` | Clean-room protocol spec, verified end-to-end against a physical oven (model `meerkat`) | **Primary.** Every protocol constant below comes from here |
| Same repo, `src/pairing.ts`, `src/protocol.ts`, `docs/reference/june_pair.py` | Working implementations of the spec | **Primary**, and they resolve several items the prose spec lists as open (§2.1) |
| `mvanhorn/printing-press-library` → `internal/june/testdata/vectors.json` | Byte-exact synthetic conformance vectors (signature, SRP, Damm, secretbox) | **Primary for testing.** This is how we prove our crypto without an oven |
| Kimi report (attached zip) | Research synthesis: hardware, cloud architecture, legal/safety envelope, junecloud plan | **Good context, secondary for protocol.** Its protocol chapter restates keithah's spec; cite keithah, not the report |
| `sanjay900/igrill` | Weber iGrill BLE integration | **Not relevant to June** — see §2.2 |

### 2.1 Corrections to carry forward

The Kimi report is dated 2026-08-01 and its schedule ("Day 1 = 2026-08-03") has
already burned a week. Four further corrections, all verified against the code:

1. **The Homebridge plugin already supports endpoint overrides.**
   `src/protocol.ts` takes optional `baseUrl` / `wsUrl` and falls back to the
   June constants (`protocol.ts:64,66,128,130`). The report's Phase 4
   "add a transport-override PR upstream" is mostly already done. The real
   remaining gap is `src/protocol-decode.ts:13`, which hardcodes
   `CAMERA_HOSTS = {api.junelife.com, june-api.s3.amazonaws.com}` and would
   reject camera frames from a replacement cloud. That is the PR worth sending.
2. **Two of the spec's four "open items" are closed by the shipped code.**
   `pairing.ts` constructs the SRP server from `this.status.shownCode` — the
   displayed 8-digit code *including* the Damm check digit — so that is the SRP
   password. And `x = SHA1(salt ‖ SHA1("user:" + PIN))` is explicit at
   `pairing.ts:131-132`. Do not re-derive these.
3. **The cert-expiry claim is unverified from here.** The report says the
   `*.junelife.com` GoDaddy wildcard expires 2026-08-18. Probing the hosts from
   this environment returns our own egress proxy's re-signed certificate, not
   June's, so we cannot confirm or refute it. Treat 2026-08-18 as a *possible*
   early breakage date, not an established one. The hosts do still answer TLS.
4. **The attached zip contains `com.junelife.companion-1.24.1.11.apk`.**
   `docs/CLEANROOM_RULES.md` forbids committing APK binaries. Record the hash
   (`sha256 e9de2c3af3fd07a12984f2b460f51ee8139df5156e0b8a20827aabecc03635b7`) and
   the signer DN; never commit the file. Same for decompiled sources.

### 2.2 iGrill: adjacent, not shared

Checked directly. `sanjay900/igrill` is a pure BLE integration for the Weber
iGrill probe: vendor service `06EF000x-2E06-4B79-9E33-FCE2C42805EC`, plus
`64AC000x-…` and `6C91000x-…` families, and an AES challenge handshake that is
bypassed by echoing the device's encrypted challenge straight back
(`igrill.py:209-227`). It shares **no protocol surface with the June oven** — no
Ed25519, no SRP, no cloud. The only real link is corporate: Weber owns both, and
the Kimi report establishes that Weber's current grill app `com.weber.connect` is
built on the June codebase.

That makes iGrill a *separate, cheap opportunity*, not a June input: it is BLE, it
is a thermometer like the four already in the registry (`ibbq`, `inkbird`,
`thermopro-tempspike`, `chef-iq-sense`), and it would drop into the mobile app's
existing spec-driven architecture with **zero new transport work**. Recommend
filing it as its own target. Do not let it into the June scope.

There is one real link, and it is the origin of the "June was going to get
Bluetooth" story: a former June/Weber oven engineer says he did R&D on unifying
the oven and grill software, which *could* have brought local BLE control. It was
deprioritized when the oven was discontinued and there is no evidence it ever
reached firmware. `targets/june-oven.md` § "Bluetooth: intended, never shipped"
has the sourcing and the one cheap experiment that would settle it. The same
engineer says the oven's code is otherwise **bespoke** and shares essentially
nothing with Weber's other connected products — so the report's suggestion that
Weber's grill line is a standing early-warning feed for June protocol evolution
does not hold for oven firmware. Do not staff a workstream on it.

---

## 3. Protocol facts (for the spec author)

All from `JUNE_INTEGRATION_SPEC.md` unless noted. Do not restate the report's
narrative; record these.

**Hosts.** `https://api.junelife.com` (REST `/2/…`),
`https://messaging.junelife.com` (REST `/1/messaging/device/{ovenId}/status`, and
`wss://messaging.junelife.com/1/messaging/websocket/companion`),
`recipes.junelife.com` (recipe catalog, never captured). Each has a `dev-` staging
twin per APK strings.

**Auth.** No user account. `POST /2/devices/register` with a random `device_id`,
a random 32-hex `password`, and app-constant `client_id`/`client_secret` returns a
7-day Bearer token (`expires_in: 604800`). "Refresh" = re-register the same
`device_id`; `grant_type=refresh_token` is rejected with `unsupported_grant_type`.
The `client_id`/`client_secret` are hardcoded in the app and identical for all
users — record them as protocol constants, not credentials.

**Pairing.** SRP-6a with **inverted roles**: the companion is the SRP *server*,
the oven is the client. RFC 5054 8192-bit group, **g = 19**, SHA-1, identity
`I = "user"`, 16-byte random salt. Password = the displayed 8-digit PIN
(cloud-issued code + Damm check digit). Seal key `K = BLAKE2b-256(S)`;
`companion_info = base64(nonce(24) ‖ crypto_secretbox_xsalsa20poly1305(json, nonce, K))`.
`POST /2/devices/pairing/{code}/companion` with `{salt, B, companion_info}`.
**Do not `DELETE` the pairing session early** — the oven has not finished SRP yet
and will emit `10027 PairingSessionInvalidated`. Wait for the second `10026`
carrying `oven_info`, then `GET /2/devices/{deviceId}/associated` for the
`oven_id`.

**Frame envelope.** Compact JSON, **exact key order**:
`v, message_code, order, time, signature, device_name, device_id, data, target`.
`order` strictly increasing, echoed back as `request_order`.

**Signature — the part that matters.** 72 bytes:
`base64( BLAKE2b(ed25519_pubkey, digest_size=8) ‖ Ed25519_sign(privkey, canonical_json) )`,
computed over the envelope with `signature` set to `""`. The 8-byte prefix is
`crypto_generichash(pubkey, 8)` — a BLAKE2b with 8-byte *output length*, not a
truncated BLAKE2b-512. **A wrong signature is silently dropped**: no ack, no
error. Standard base64, not url-safe.

**Message codes.**

| Dir | Code | Meaning | `data` |
|---|---|---|---|
| → oven | 11011 | keepalive (~7 s) | `{}` |
| → oven | 11002 | preheat / start cook | `{"primitive_type":"bake","temperature_cavity":<milliC>}` |
| → oven | 11005 | change target temp | `{"plan_id":0,"temperature_cavity":<milliC>}` |
| → oven | 11006 | set timer | `{"plan_id":0,"duration":<ms>}` |
| → oven | 11004 | cancel | `{"plan_id":0}` |
| ← oven | 10020 | ack | `{"request_order":<int>,"status":"success"｜"not-allowed"｜"door-open"｜"not-ready"｜"cleaning"}` |
| ← oven | 10018 | device state | `{"state":"idle"｜"active"}` |
| ← oven | 10013 | telemetry ~1/s | `sensor_data.cavity` (milliC), `sensor_data.probe[]`, `cook_state_data.progress` |
| ← oven | 10014–10017 | cook plan started / updated / temp changed / cancelled | plan structures |
| ← oven | 10011 | camera frame | `{video_id, ts, signed_url, image_url, content_type, image_size}` |
| ← oven | 10026 / 10027 | pairing info / session invalidated | `data.key_info` |

**Units.** Integer milli-degrees Celsius. `milliC = round((°F − 32) × 5/9 × 1000)`;
350 °F = 176667. Probe presence is *structural* — a non-empty `sensor_data.probe`
array; there is no `food_present` field.

**Verified limits.** A running cook's target cannot be retargeted — both 11005 and
a re-issued 11002 are rejected; clients cancel and restart. Camera is ~1 fps
stills, never video. Only `bake` and `roast` are confirmed on-oven; the rest of
the mode vocabulary was never enumerated. Door state is observable only as a
`10020 status:"door-open"` rejection, never as a push.

**No local path.** Wi-Fi is provisioned on the oven's own touchscreen. No mDNS,
SSDP, UPnP, local HTTP, or documented BLE control surface. One unverified
community report of an open TCP port 8156 on the oven — record it as a
hypothesis, nothing more.

---

## 4. Work orders

### 4.1 D1 — the device spec (this repo)

Branch: `claude/june-oven-support-plan-mk9kwr`.

**Files**

1. `device-specs/devices/june-oven.yaml`
2. `docs/devices/june-oven.md` — device page, from `docs/devices/_template.md`
3. `targets/june-oven.md` — already written by this plan; extend if new facts land
4. `mkdocs.yml` — add the device page to `nav` (CI runs `mkdocs build --strict`)

**Not** `device-specs/index.json`. This plan predates the current policy: the
file is generated, CI rebuilds and commits it on `main`, and a branch carrying
it fails CI — it is the file every parallel spec PR used to conflict on. Run
`python scripts/generate_index.py` locally if you want to look at it, but never
stage it. See `CLAUDE.md` and `AGENTS.md`.

**Spec shape.** `niu-escooter.yaml` is the closest precedent — a cloud-only device
whose spec exists to record the dependency honestly. Follow it. Skeleton:

```yaml
device:
  name: "June Intelligent Oven"
  manufacturer: "June Life, Inc. (Weber-Stephen Products LLC)"
  manufacturer_status: "shutdown"      # cloud retired 2026-09-22
  protocol: "wifi"
  openness:
    status: "undocumented"
    reverse_engineered: true
  identification:
    default_port: 8156                 # UNVERIFIED — see notes; consider omitting
  setup:
    required: true
    confidence: "high"
    methods:
      - type: "device_ui"              # Wi-Fi is entered on the oven's touchscreen
      - type: "cloud_account"          # 8-digit PIN pairing via June's cloud
  notes: >
    CLOUD-ONLY ...
cloud:
  required: true
  vendor_service: "June cloud"
  hosts: ["https://api.junelife.com", "https://messaging.junelife.com"]
  auth:
    type: "oauth2"
    endpoint: "/2/devices/register"
    verification: "confirmed"
  endpoints: [...]
local_access:
  status: "none_known"
  summary: >
    No local control path is known on stock hardware ...
  not_covered: [...]
```

**Judgement calls the executing agent must make deliberately, not by default:**

- `manufacturer_status`: `shutdown` is right — the enum documents *why the device
  needs rescue*, and the cloud being retired is exactly that. Not `abandoned`.
- `identification.default_port: 8156` — the schema field means "default TCP port
  for the device's local API". Port 8156 is a single unverified community remark.
  **Recommendation: omit the field and record 8156 in `notes` as a hypothesis.**
  Putting an unverified port in an identification field invites a consumer to
  probe on it.
- The pairing crypto (SRP group, seal construction, 72-byte signature) does not
  fit any typed schema block. Put it in a bespoke top-level `pairing:` block —
  the schema is explicitly permissive about unknown keys ("bespoke,
  device-specific metadata … can travel alongside the standard fields") and the
  Rust consumer sweeps unknown top-level keys into `extensions`. Precedent:
  existing specs carry `protobuf`/`state_machine` blocks the same way.
- Do **not** invent a `services:` block. There is no GATT surface.
- `advanced` flag: `11002` preheat starts a heating element remotely. Per
  `docs/CLEANROOM_RULES.md` the flag is a signpost, not a gate — flag the cook
  commands `advanced` with an `advanced_reason` that states the real consequence
  (an unattended oven preheats; June shipped a remote-preheat disable and a
  30-minute no-food auto-off after documented 2019 incidents) and note that both
  mitigations live on the oven and must never be worked around.

**Acceptance:** `python scripts/validate_specs.py` passes; `python
scripts/build_index.py --check` passes; `mkdocs build --strict` passes;
`ruff check .` passes; `pytest -q` passes. Do not gate on a clean
`git diff` of `device-specs/index.json` — satisfying that means committing the
regenerated file, which is exactly what CI rejects.

### 4.2 D2 — the app (mobile repo)

See `liberatedbread-mobile/JUNE_OVEN_PLAN.md`. Summary of the shape so this
document stands alone:

June is the first device in the app that is **not BLE, not spec-driven, and has
no local presence at all**. The Rust core today carries no networking and no
crypto (`serde`, `serde_yaml`, `indexmap`, `thiserror`, `anyhow` — that is the
whole dependency list) and the Dart side speaks BLE plus HTTP-to-Home-Assistant.
So this is genuinely new surface, not a spec drop.

Recommended split, matching the repo's existing division of labour ("Rust handles
protocol logic; Flutter handles the transport"):

- **Rust**: canonical frame construction and key ordering, the 72-byte signature,
  Ed25519/BLAKE2b/secretbox, SRP-6a, Damm, milli-°C conversion. All of it is
  testable against `vectors.json` in CI with **no oven and no network**.
- **Dart**: HTTPS and WSS sockets, keychain storage of the seed and device
  password, pairing UI, control surface.

The single non-deferrable decision: **endpoint base URLs are configuration from
the first commit**, never constants. That is what lets the same build talk to a
replacement cloud in October.

### 4.3 Ship the export flow even if D2 slips

Whatever else happens, the app should be able to **export the pairing material** —
`oven_id`, `device_id`, `device_name`, `password`, `ed25519_seed_hex` — as JSON.
That set is what every other client (Homebridge, Home Assistant, the Go CLI, a
future junecloud client) needs, and after 2026-09-22 it cannot be re-minted
without a replacement cloud. It is a small feature with an expiry date on its
value. Treat it as part of D2's first milestone, not its last.

The UI must say, once and factually: pairing runs through June's servers and
stops working 2026-09-22; keep this export; and — the one piece of advice that
is not ours but is worth repeating — **do not factory-reset the oven**, because
first boot requires a cloud software update.

---

## 5. Sequencing

Dates assume a start of 2026-08-08.

| Order | Work | Blocked by | Deadline logic |
|---|---|---|---|
| 1 | D1 spec + device page + index (§4.1) | nothing | none — do it first because it is cheap and permanent |
| 2 | Rust crypto/frame layer, green against `vectors.json` (§4.2) | nothing — no oven, no network | none |
| 3 | Pairing + export flow (§4.3) | 2 | **2026-09-22** — pairing dies with the cloud |
| 4 | Control + telemetry + camera | 2, 3 | 2026-09-22 for live validation against a real oven |
| 5 | Upstream PR: unpin `CAMERA_HOSTS` in homebridge-june-oven (§2.1) | nothing | none |
| 6 | LAN/IP recon, if anyone has an oven (§5.1) | nothing | **passive capture only** |

Only steps 3, 4 and the passive half of 6 have a real deadline, and only because
that is when observing a live system becomes impossible. Steps 1, 2 and 5 are
indifferent to the shutdown — which is a reason to start them now, not a reason
to rush them.

### 5.1 The IP-level work, and a correction to its urgency

`docs/devices/june-oven-lan-recon.md` is the playbook: bench rig, a tiered
experiment ladder, and `scripts/june_discover.py` for the active scan. Two things
from it belong in the schedule here.

**Passive capture is the perishable half, and it is not the one the research
report prioritises.** That report puts the certificate-pinning experiment first
with a Day-7 deadline. On inspection that is backwards. In a DNS-redirect bench
you answer the oven's DNS query yourself and present your own endpoint — Weber is
not in the path at all, so the experiment needs only the oven to keep dialling,
which a cloud-orphaned appliance does indefinitely. It will run just as well in
December. What genuinely dies on 2026-09-22 is everything that needs a June
server to *respond*: the OTA manifest, the provisioning flow, the recipe catalog,
and a recording of one legitimate session.

So if anyone on this project has a physical oven, the next 46 days should go to
`tcpdump`, not to certificate ladders. The single highest-value artifact is the
oven's own **DNS query log**, because it names the update host — which the
companion APK cannot, since firmware delivery is oven-side and static analysis
found no OTA strings in the app at all. Nobody has published it for any
generation.

One caveat to verify rather than assume: confirm after the shutdown that the oven
still dials. Lengthening retry backoff is fine; firmware that gives up
permanently would close the window after all, and passive capture is what tells
you.

**A clock problem may gate the whole replacement-cloud idea, independently of
pinning.** Weber's FAQ says the oven's clock is cloud-dependent. TLS validation
needs a roughly correct clock. If the oven takes time from June's cloud rather
than public NTP, then after the shutdown it may fail TLS against *any* server —
including a replacement — with `certificate_expired`, for reasons unrelated to
trust. That would mean a replacement cloud has to answer NTP too. It is settled
by one grep over a passive capture, so it costs nothing to find out, and it is
worth knowing before anyone budgets a server build.

## 6. Guardrails

`docs/CLEANROOM_RULES.md` applies in full. Specifically for this target:

- **Never commit** the APK, decompiled sources, or vendor UI assets. Hashes,
  endpoint paths, UUIDs, message formats and protocol constants are fine.
- **Never commit** a real token, `oven_id`, `device_id`, Ed25519 seed or device
  password — not in a test fixture, not in a doc example. Use the synthetic
  `vectors.json` values, which exist precisely for this.
- **Never ship anything that touches the cook loop.** The oven's 1 Hz control
  loop and its temperature-limiting hardware stay sovereign. We are writing a
  companion that sends the same five opcodes the vendor's own app sends.
- **Reimplement the ack vocabulary exactly.** `door-open`, `not-ready`,
  `cleaning` and `not-allowed` are the protocol's safety channel; surface them
  to the user verbatim rather than collapsing them into "failed".
- Scope is owner-operated repair on hardware the user owns. That is squarely
  what `CLEANROOM_RULES.md` describes as the point.
