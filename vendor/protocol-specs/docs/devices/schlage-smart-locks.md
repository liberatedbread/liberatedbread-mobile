# Schlage Smart Locks (Sense / Encode family)

> **Status**: Complete
> **Protocol**: BLE (uWeave GATT); WiFi is cloud-relay only
> **Manufacturer**: Schlage (Allegion)
> **Manufacturer Status**: Active

## Overview

Schlage's residential smart locks — Sense (BE479), Encode (BE489), Encode Plus
(BE499) and Encode Lever — all speak the same proprietary BLE protocol: a
uWeave-derived GATT profile carrying CBOR "Privet" RPC inside an AES-128-EAX
session channel, paired via SPAKE2/P-224 against the lock's printed programming
code. Once paired, **every owner function works locally over BLE with no
cloud**: lock/unlock, state (battery/door/alarm), settings, access-code
management, history logs, time sync, firmware OTA and factory reset.

The WiFi radios on the Encode family have **no local-network API at all** —
runtime WiFi traffic is a cloud relay (REST + MQTT-over-WebSocket against
`*.allegion.yonomi.cloud`). This page documents the BLE path, which is the
local-control surface. Schlage/Allegion is an active manufacturer; this spec
exists because local control matters for latency, privacy and resilience, not
because the vendor disappeared.

Protocol facts here were recovered from the Schlage Home Android app
(`com.allegion.leopard` 3.6.0 and 6.1.0, jadx) and cross-checked against the
independent Go reimplementation
[schlage-uweave](https://github.com/huguesb/schlage-uweave), which agrees on
every constant checked. Facts not independently re-derived are marked
*(reported)*.

## Hardware

| Property | Value |
|----------|-------|
| Models | Sense BE479, Encode BE489, Encode Plus BE499, Encode Lever |
| Radio | BLE (all); WiFi (Encode family); Thread + NFC (Encode Plus) |
| FCC ID | XPB-JACKALOPE (Encode Plus; EFR32MG12 BLE/Thread + NXP NFC) |
| App | Schlage Home, `com.allegion.leopard` |

### Per-model radios and local paths

| Model | Radios | Local control path | Cloud-only bits |
|---|---|---|---|
| Connect BE468/BE469 | Z-Wave S2 | Z-Wave (different product, not this page) | — |
| Sense BE479 | BLE (+ optional BR400 WiFi adapter) | **uWeave BLE** or Apple HAP-over-BLE (mutually exclusive) | CAT minting for non-owner users |
| Encode BE489 | WiFi + BLE | **uWeave BLE** | WiFi onboarding (JITR), CAT minting, firmware metadata |
| Encode Plus BE499 | WiFi + BLE + Thread + NFC | **uWeave BLE**, or HomeKit over Thread/BLE + NFC Home Key | same as Encode |
| Encode Lever | WiFi + BLE | **uWeave BLE** | same as Encode |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — SPAKE2 pairing before any command works |
| Method | `ble_provisioning` |
| Advertised in Schlage mode | DataTransfer service UUID `1F6B43AA-94DE-4BA9-981C-DA38823117BD` |
| Pairing secret | Programming code printed inside the lock |
| Confidence | medium (decompiled app + working open implementation; not replayed on hardware by us) |

**Pairing secret**: the programming code on the label inside the lock (and in
the manual). Possession of it plus BLE range equals full local control — treat
it as a physical secret. Pairing must happen in Schlage mode; a lock paired to
HomeKit must be switched modes first, which wipes access codes.

**Factory reset**: available over the protocol itself (trait 3 op 3, flagged
`advanced`) — clears access codes, paired credentials and configuration. The
physical button sequence is per-model in Schlage's manuals and is not
reproduced here.

**Re-pairing / rejoining**: a paired client reconnects with its stored SAT/CAT
macaroons and only reruns the session handshake (phase C) — no reset, no
programming code. One active BLE session at a time: while a third-party client
is connected, the official app silently falls back to its cloud path.

## Protocol Summary

### BLE Services

| UUID | Name | Notes |
|------|------|-------|
| `883f45ec-14cb-46aa-9864-9a4e782b33d0` | uWeave Profile | the local control path; **not** advertised — discovered after connect |
| `26002998-e001-4812-8c08-5cd2afda0830` | RxData (lock→client) | indicate (CCCD `00002902-…`) |
| `ff530c78-cd50-4bb9-bbd4-0712f32b3796` | TxData (client→lock) | write |
| `7f0dee73-4a3f-4103-98e6-a46cd301bdfb` | FW Update "General" | FWImageVersion `BCDE3B9E-…`, LeopardControlPoint `44FF6853-…` (`{1,1,1}` start / `{2,1,1}` finish) |
| `1F6B43AA-94DE-4BA9-981C-DA38823117BD` | FW Update "DataTransfer" | RxLength `048D8799-…`, RxData `66B7C7FD-…`, RxCRC `507EFC3F-…`, RxACKNAK `1DC15719-…`; also the UUID advertised in Schlage mode |

The UUIDs ship as JSON raw resources in the APK (`res/raw/sense_gatt_profile.json`,
`res/raw/firmware_gatt_profile.json`), byte-identical between app 3.6.0 and
6.1.0.

### Fragmentation

No MTU negotiation (default ATT MTU 23): every write/indication is
`1 header byte || ≤19 payload bytes`. Header = `(packetCounter mod 8) << 4 |
flag`; flags `0x8` FIRST, `0x0` CONTINUATION, `0x4` LAST, `0xC` SINGLE. Control
packets set bit 7 with the command in the low nibble (0 = connection request,
1 = connection confirm). Maximum reassembled message block: 1024 bytes.

### Pairing phases A–D

The app is always the client; the lock is the server. Long-term credentials are
two macaroons: **CAT** (Client Authorization Token) and **SAT** (Server
Authentication Token). A full pairing runs A→D once; every later session enters
at C with fresh randoms.

- **Phase A — unsecured connection request.** Connect, discover services,
  enable RxData indications, send the control packet (cmd 0) with crypto mode
  0. Unfragmented, unencrypted.
- **Phase B — SPAKE2/P-224 pairing** (password = printed programming code):
  1. Client sends pairing start `{1:2, 2:1, 16:{0:1, 1:0}}`.
  2. Lock replies `{17:{0:sessionID, 1:serverCommitment(56B)}}`.
  3. `passwordHash = BigInteger(SHA256(code)[0:28])`; client commitment
     `T = x·G + passwordHash·KM` (56-byte affine x‖y, no prefix); shared key
     `K = x·(S − passwordHash·KN)`; pairing-phase AES key = `K[0:16]`.
  4. Timestamp proof = AES-128-EAX (96-bit tag) of `CBOR({0:unixTimeSec})`
     under that key with fixed 1-byte nonces (`0x00` client→lock, `0x01`
     lock→client).
  5. Client sends `{1:3, 2:2, 16:{0:sessionID, 1:clientCommitment,
     2:encryptedTimestamp}}`.
  6. Lock replies `{17:{0:EAX blob}}` → decrypt → `CBOR {0:CAT, 1:SAT}`.
- **Phase C — secure connection request + SAT extension** (the session
  resumption entry point): connection request with crypto mode 2
  (`TOKEN_SHA256`) followed by a raw 12-byte `clientRandom`. The lock replies
  with `serverRandom`; the client attenuates the SAT with an
  `authentication_challenge` caveat (`0x14`, HMAC-SHA256 keyed by the SAT tag
  over `1 ‖ clientRandom ‖ serverRandom`, truncated to 16 bytes) and sends it;
  the lock answers with the matching HMAC. Session keys:
  `IKM = 0x02 ‖ clientRandom(12) ‖ serverRandom(12) ‖ satTag(16)`, then
  HKDF-SHA256 with the fixed 32-byte salt
  `008A393622041F5F0FC75D97DAEE6E81CBBB2BC74F9CCC91E75E77A56B4A4B05`,
  `expand(info="session key", 32)` → first 16 bytes AES-128 session key, last
  16 nonce base.
- **Phase D — authorization and access-control claim:**
  `{1:5, 2:3, 16:{0:1, 1:0, 2:CAT}}` → `{1:24, 2:4}` (claim) → lock returns the
  new CAT → `{1:25, 2:5, 16:{0:CAT}}`. Then housekeeping: timezone, DST, read
  serial/model/firmware. Store `{sat, cat, userId, model, serial, mac,
  firmware}`.

### Session cipher

AES-128-EAX, 96-bit tag, no AAD. Nonce =
`nonceBase(16) ‖ senderID(1) ‖ counter(3, big-endian)`; client→lock senderID
`0x01`, lock→phone `0x03`; counters from 1 per session. Whole CBOR messages are
encrypted before fragmentation; reassemble, then decrypt.

### Macaroon wire format

`CBOR bstr( array(N) bstr(caveat₁)…bstr(caveat_N) bstr(mac_tag) )`; the tag is
an HMAC-SHA256 chained over caveats, truncated to 16 bytes. Attenuation appends
a caveat and recomputes the tag. CAT/SAT are **bearer tokens** — a dumped
client database plus BLE range grants control without the programming code.

### Command layer (CBOR "Privet" RPC)

Envelope: request `{1:apiId, 2:requestTypeId, 16:{trait, property, data}}`;
success result at key `17` (often nested 17→17); error code at `3 → 4`.
apiIds: 2=pairing start, 3=pairing confirm, 5=auth(CAT), 6=state query,
8=trait/property RPC, 24=claim, 25=claim confirm. Key 2 is a fixed per-command
constant (1=DST write, 2=check/FDR/delete, 3=pairing-CAT/list-check/
history-read/state, 4=reads/WiFi/claim, 5=deleteAll/claim-confirm/JITR,
7=writes). Traits: 1=LockData, 3=History/DeviceMgmt, 4=AccessCodes,
5=LockConfig, 6=WiFi.

| Operation | Wire format | Verified |
|---|---|---|
| Lock / Unlock | `{1:8,2:7,16:{0:1,1:0,2:{0:stateOrdinal,1:userId(8B BE)}}}` | in app code |
| Lock state | `{1:6,2:3}` → keys 0=status, 12=batteryState, 14=alarmEnabled, 21=batteryLevel, 25=doorState | reported |
| Read info | `{1:8,2:4,16:{0:1,1:P}}` P: 2=mfr, 3=model, 4=serial, 5=main FW, 7=time, 12=battery, 15=ext FW | in app code |
| Set time | saveData trait 1 prop 6 (unix secs) | reported |
| Read settings | trait 5: 3=beeper, 5=autoLockTime, 9=alarmMode, 11=alarmSensitivity, 13=lockAndLeave, 15=codeLength, 21=tz, 27=opMode | reported |
| Write settings | trait 5: 2=beeper, 4=autoLockTime, 8=alarmMode, 10=alarmSensitivity, 12=lockAndLeave | reported |
| Set timezone / DST | trait 5 prop 20 (minutes) / `{1:8,2:1,16:{0:5,1:18,2:{0:1,1:start,2:end}}}` | reported |
| Set access-code length | `{1:8,2:2,16:{0:5,1:14,2:{0:len}}}` | in app code |
| Add/update access code | `{1:8,2:3,16:{0:4,1:(0=add,4=update),2:{0:userUuid(8B BE),1:name,2:code,3:sched1,4:sched2,5:blocked,6:startEpoch,7:endEpoch}}}` | in app code |
| Delete code / delete all | `{1:8,2:2,16:{0:4,1:1,2:{2:code}}}` / `{1:8,2:5,16:{0:4,1:2}}` (advanced) | in app code |
| List codes | check `{1:8,2:3,16:{0:4,1:6,2:{0:0}}}` + read `{1:8,2:4,16:{0:4,1:5}}` (paged, moreAvailable key 0x0A) | reported |
| History logs | check `{1:8,2:2,16:{0:3,1:0,2:{0:0}}}` + read `{1:8,2:3,16:{0:3,1:batchSize}}` | reported |
| Factory reset | `{1:8,2:2,16:{0:3,1:3}}` (advanced) | reported |
| WiFi credentials | `{1:8,2:4,16:{0:6,1:0,2:{0:ssid,1:password,2:security}}}` | reported |
| WiFi JITR payload0 | `{1:8,2:4,16:{0:6,1:2,2:{0:payload0Bytes}}}`; status `{1:8,2:5,16:{0:6,1:4}}` → 0..5 (enum ends at IP_ACQUIRED; no state 6) | reported |
| Firmware OTA | separate GATT profile (above) | UUIDs in app resources |

Enums: lockState 0=unlocked, 1=locked, 2=jammed, 3=unknown, 4=motorJammed,
5=passage, 6=deadlocked. doorState 0=unknown, 1=open, 2=closed, 3=faulty.
opMode 0=Schlage BLE only, 1=simultaneous BLE+Matter (supported hardware only).

## What needs the cloud — and what doesn't

Works with **no cloud**, once paired: lock/unlock, state (battery/door/alarm),
settings, access-code CRUD, history download, time sync, firmware OTA
mechanics, factory reset.

Genuinely cloud-dependent:

- **First-time WiFi onboarding (Encode family):** the lock's AWS IoT identity
  ("payload0" JITR blob) is minted by `factory.allegion.yonomi.cloud` and
  pushed to the lock over BLE (trait 6 prop 2). No cloud, no WiFi onboarding.
- **CAT minting for non-owner users on non-Sense locks** (CatStar service).
- **Firmware metadata and binaries** (`api.allegionengage.com` — metadata at
  `GET /api/firmware/{platformType}`, binary URL server-supplied, and the app
  verifies content-length only; WiFi locks can also self-download over WiFi,
  manual trigger: interior button ×5).
- **Remote access, push notifications, multi-user invites.**

The consumer cloud path itself is AWS Cognito SRP login plus REST
`api.allegion.yonomi.cloud/v1` with an API-key header, realtime via per-device
MQTT-over-WebSocket, TLS-pinned to Amazon Root CAs. (The app-embedded key and
secret are vendor client credentials; only the shape is recorded here, per the
clean-room rules.) There is **no local WiFi runtime API**: the app never opens
a socket to a lock and the lock hosts no softAP or listener (3.6.0 code-level
confirmation, 2026-08), no SSDP, and the only mDNS observed is the Encode
Plus's HomeKit `_hap._udp` record — Apple's protocol, mutually exclusive with
Schlage-mode pairing. A full-/16 LAN census of a household with three
commissioned locks (2026-08-14) found no lock-like listener on any host. The
one local WiFi surface in the family is the Sense's optional **BR400 adapter**,
which exposes an *unauthenticated* LAN HTTP API — including a firmware-update
endpoint taking an arbitrary URL — documented in
`research-notes/schlage-wifi-local-surface.md`; it is accessory-scoped and
does not exist on Encode-family locks.

## Live verification (2026-08)

Read-only check against three commissioned household locks (front / kitchen /
laundry doors), 2026-08-14, BlueZ + bleak on the home LAN. No pairing was
attempted (SPAKE2 needs the printed programming code) and nothing was written
to any lock.

- **BLE presence confirmed**: one lock was captured advertising once — complete
  local name `SCHLAGE` + 8 uppercase hex digits (serial-looking suffix), public
  address with OUI `B7:AC:C2` (partially recorded), RSSI −74 dBm, manufacturer
  data under Bluetooth company ID **315 = Allegion** embedding the device's own
  MAC. Which door it belongs to is not yet mapped.
- **Advertised-UUID claim not observed**: that single advertisement carried
  **no service UUIDs** — not the DataTransfer UUID
  `1F6B43AA-…` this page says Schlage-mode locks advertise. One sample from a
  commissioned lock (commissioned locks are known *reportedly* to change their
  advertising), so treat as "not observed", not refuted.
- **Idle locks barely advertise**: ~75 minutes of further scanning caught zero
  more advertisements from any of the three locks, so no GATT connection —
  and hence no GATT-table verification — was possible. The service tables
  above remain app/Go-library-derived. To verify on hardware, wake a lock
  (keypad touch) while scanning.
- **No HomeKit-mode unit**: no lock advertised `SENSE  ` (HAP-over-BLE) and no
  `_hap._udp` mDNS record exists on the LAN — no Encode Plus in HomeKit mode
  here.
- **LAN silence consistent with "no local WiFi API"**: full mDNS enumeration
  and an SSDP M-SEARCH turned up nothing Schlage; no Schlage/Allegion OUI
  exists in the IEEE registry, so lock IPs couldn't be identified for port
  scanning. The locks make no LAN discovery announcements at all, matching the
  cloud-relay-only claim (absence-of-evidence caveat applies).

## Building a local client

- **Fastest:** [schlage-uweave](https://github.com/huguesb/schlage-uweave)
  (Go) already implements transport, pairing, macaroons, session crypto and
  the command map.
- **DIY (e.g. Python + bleak):** implement fragmentation, phases A/C, AES-EAX
  with the nonce construction above, HKDF with the recovered salt, and the
  CBOR tables. All constants are on this page and in
  [`device-specs/devices/schlage-smart-locks.yaml`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/device-specs/devices/schlage-smart-locks.yaml).
- One active BLE session at a time; while your client is connected, the
  official app falls back to cloud.

## Tools Used

- [x] apkeep (APKPure) — APK acquisition: `com.allegion.leopard` 3.6.0
  (sha256 `73ad7395…`) and 6.1.0 (sha256 `0e87604d…`)
- [x] jadx 1.5.1 — decompilation (3.6.0 readable; 6.1.0 Java is packed by a
  commercial protector, resources extracted directly)
- [x] Cross-check against the public Go implementation

## References

- [schlage-uweave (Go)](https://github.com/huguesb/schlage-uweave) — independent reimplementation of the BLE protocol, used as the cross-validation oracle
- [pyschlage](https://github.com/dknowles2/pyschlage) — Python client for the Schlage **cloud** API; backs the Home Assistant `schlage` integration
- [FCC ID XPB-JACKALOPE](https://fccid.io/XPB-JACKALOPE) — Encode Plus internals
- Apple Platform Security — HomeKit/HAP cryptographic design (not re-derived here)

## Contributors

- Liberated Bread research — APK teardown and verification against the Go implementation
