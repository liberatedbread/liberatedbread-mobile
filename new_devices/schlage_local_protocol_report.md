# Schlage Smart Locks — Local Protocol Investigation (WiFi + BLE, No-Cloud Focus)

**Date:** 2026-08-02
**Method:** Prior-art review (Home Assistant community, GitHub, FCC filings, vendor docs) + acquisition and decompilation of the official **Schlage Home** Android app (`com.allegion.leopard`, versions 3.6.0 and 6.3.1) with jadx/apktool, followed by protocol extraction and cross-validation against the public Go reimplementation `golang.betakappaphi.com/schlage-uweave`.

---

## 1. Executive summary

- **Schlage's residential WiFi locks (Encode BE489, Encode Plus BE499, Encode Lever) have no local-network control API.** All runtime WiFi traffic is a cloud relay: REST against `api.allegion.yonomi.cloud/v1` plus an AWS-IoT-style MQTT-over-WebSocket realtime channel. No local REST server, no open port, no SSDP, and the only mDNS advertisement ever observed on a LAN is the **Encode Plus's HomeKit `_hap._udp` record** (which is Apple's protocol, not Schlage's). The APK contains no client code that talks to a lock over the LAN — post-provisioning, it is BLE or cloud, nothing else.
- **The real local protocol is BLE, and it is fully documented here.** Schlage locks speak a proprietary but reverse-engineered stack: a **uWeave-style GATT profile** (service `883f45ec-14cb-46aa-9864-9a4e782b33d0`), 20-byte fragmented writes, **SPAKE2/P-224 pairing** keyed by the lock's printed programming code, **macaroon** bearer credentials (SAT/CAT, 16-byte truncated HMAC-SHA256 tags), **HKDF-SHA256** session-key derivation, **AES-128-EAX** session encryption, and a **CBOR "Privet" RPC envelope** with a fully enumerated trait/property command set (lock/unlock, state, access-code CRUD, history logs, settings, factory reset, WiFi config, firmware OTA).
- **Everything a user can do locally works over BLE without any cloud**, once paired: lock/unlock, status (incl. battery/door/alarm), settings (beeper, auto-lock, alarm, lock-and-leave), access-code management, history download, time sync, firmware update, and even factory reset. Cloud is required only for onboarding of WiFi credentials (the JITR "payload0" blob is minted by Schlage's factory cloud), CAT minting for non-Sense locks, firmware metadata, invites, and push notifications.
- **The pairing secret is the lock's physical programming code** (printed inside the lock). Possession of it plus BLE range = full local control. Session security after pairing is solid (fresh randoms + HKDF per session); the static pairing-phase cipher is weaker (fixed 1-byte nonces), which only matters against an eavesdropper present during initial pairing.
- **Two independent implementations agree:** the APK extraction matches the public Go library `schlage-uweave` on every load-bearing detail (UUIDs, header bit layout, SPAKE constants, HKDF salt, EAX nonce format, macaroon wire format, full command map). A working local client already exists in Go; a Python/pyschlage-style local implementation is straightforward from the data in §4–§6.
- **Other genuinely local paths:** Schlage Connect (Z-Wave S2, fully local via any Z-Wave controller) and Apple HomeKit HAP — Sense speaks HAP over BLE, Encode Plus speaks HAP over Thread/BLE. HomeKit pairing is mutually exclusive with Schlage-app pairing and wipes access codes; the Schlage BLE stack documented here is the better basis for third-party local control.
- **Matter:** the app contains no Matter stack. Newer hardware (codename WALTON) supports a lock-side "simultaneous mode" (Schlage BLE + Matter concurrently, toggled via BLE trait 5 prop 26). No shipping Schlage lock is Matter-only.

---

## 2. Ecosystem and radios per model

| Model | Radios | Local control path | Cloud path |
|---|---|---|---|
| Connect (BE468/BE469) | Z-Wave Plus (S2) | Z-Wave, fully local (Z-Wave JS / Keymaster) | none native |
| Sense (BE479) | BLE (+ optional BR400 WiFi adapter) | **Schlage uWeave BLE (this report)** or Apple HAP-over-BLE (mutually exclusive modes) | Schlage cloud via BR400 adapter / Apple Home hub |
| Encode (BE489) | WiFi + BLE | **Schlage uWeave BLE (this report)** | Yonomi cloud REST + MQTT/WSS |
| Encode Plus (BE499) | WiFi + BLE + Thread + NFC | **uWeave BLE**, or HomeKit HAP over Thread/BLE + NFC Home Key | Yonomi cloud |
| Encode Lever | WiFi + BLE | **uWeave BLE** | Yonomi cloud |

Device codenames in the APK (enum in 3.6.0 `defpackage/x5.java`, extended in 6.3.1): SWORDFISH=NDE, JAGUAR=Control Lock, KRILL=MT20W, TRIDENT=ADE, GATEWAY=GWE, MARLIN=Sense, LEOPARD/DENALI=Encode family, JACKALOPE=Encode Plus (FCC ID XPB-JACKALOPE, Silicon Labs MGM12P EFR32MG12 BLE+Thread module + NXP NFC frontend with ECP for Apple Home Key), plus unreleased/flagged WALTON, SCHLAGE_SELENE_*/GAINSBOROUGH_SELENE_* and WIFI_KEYPAD_DEADBOLT ("Arrive").

**Cloud boundary (for completeness):** consumer path = AWS Cognito SRP auth (user pool `us-west-2_2zhrVs9d4`), REST `https://api.allegion.yonomi.cloud/v1` with `X-Api-Key`, and realtime via per-device MQTT-over-WSS (`wssUri`/`clientId`/shadow topics `reported|desired|delta` supplied by the cloud). TLS pinning: `*.yonomi.cloud` pinned to Amazon Root CA 1–4 in `network_security_config.xml` (both APK versions) — so cloud MITM requires defeating pinning, another reason the BLE path is the practical local target. A commercial "Schlage Home API" exists at developer.allegion.com (OAuth2, webhooks) but excludes individual/hobbyist use.

---

## 3. BLE discovery and advertisement format

From `bluetooth/SenseScanner.java` (6.3.1) and the 3.6.0 equivalent:

- **Unified/Android mode:** scan record bytes `[3..21)` equal `11 06` followed by the firmware **DataTransfer service UUID `1F6B43AA-94DE-4BA9-981C-DA38823117BD`** in BLE little-endian byte order (AD type 0x06, incomplete 128-bit service list). Commissioned unified-mode locks set scan-response byte 55 = `0x82`.
- **HomeKit mode:** two AD 0x09 complete-local-name entries `"SENSE  "` (with trailing spaces) at fixed offsets; legacy SWORDFISH locks advertise Apple manufacturer data (company ID `0x004C`).
- **Device UID:** scan-record bytes `[14..20)`. Device type is parsed from the advertisement (enum includes SWORDFISH, LEOPARD/Sense, DENALI/Encode, JACKALOPE, ENCODE_LEVER, WKD/"Arrive", WALTON, SELENE variants).
- A lock advertising in HomeKit mode is detected by connecting and checking for HAP characteristic `00000014-0000-1000-8000-0026bb765291` ("Pairing Features") — used only as a mode discriminator before commissioning, never in the Schlage data path.

---

## 4. The uWeave GATT profile (the local data path)

UUIDs ship as JSON raw resources in the APK (`res/raw/sense_gatt_profile.json`, byte-identical between 3.6.0 and 6.3.1), parsed at runtime into a nickname→UUID map; the app resolves them with the standard `getService().getCharacteristic()` calls. Extracted profile:

| Role | Nickname | UUID | Properties |
|---|---|---|---|
| Service | "uWeave Profile" | `883f45ec-14cb-46aa-9864-9a4e782b33d0` | — |
| Characteristic (lock→phone) | "RxData" | `26002998-e001-4812-8c08-5cd2afda0830` | Indicate (CCCD `00002902-…-00805f9b34fb`) |
| Characteristic (phone→lock) | "TxData" | `ff530c78-cd50-4bb9-bbd4-0712f32b3796` | Write |

**Fragmentation (no MTU negotiation — default ATT MTU 23):** every write is `1 header byte || ≤19 payload bytes`. Header = `(packetCounter << 4) | flag` with counter mod 8; flags `0x8`=FIRST, `0x0`=CONTINUATION, `0x4`=LAST, `0xC`=SINGLE. Reassembly mirrors this on indications. Max message block: **1024 bytes**.

**Firmware-update profile** (separate, `res/raw/firmware_gatt_profile.json`): service "General" `7f0dee73-4a3f-4103-98e6-a46cd301bdfb` (chars FWImageVersion `BCDE3B9E-…`, LeopardControlPoint `44FF6853-…` with `{1,1,1}` start / `{2,1,1}` finish), service "DataTransfer" `1F6B43AA-94DE-4BA9-981C-DA38823117BD` (RxLength `048D8799-…`, RxData `66B7C7FD-…`, RxCRC `507EFC3F-…`, RxACKNAK `1DC15719-…`). Block/packet sizing: Sense 1024/128, newer locks 4096/241 or 1024/205.

---

## 5. Pairing and session security

The app is always the initiator/client; the lock is the server. Long-term credentials are two macaroons: **CAT** (Client Authorization Token) and **SAT** (Server Authentication Token). A full pairing runs phases A→D once; every later session enters at phase C with fresh randoms.

### Phase A — unsecured connection request
GATT connect → service discovery → enable RxData indications → send control packet: header byte `(0x8 + counter)<<4` (control, cmd 0) + CBOR version/crypto negotiation map (min/max protocol version, max packet size, crypto mode; unsecured mode terminal `20:0`). Sent unfragmented, unencrypted.

### Phase B — SPAKE2/P-224 pairing (password = printed programming code)
1. App sends pairing start: `{1:2, 2:1, 16:{0:1, 1:0}}` (pairingType 1, cryptoMethod 0).
2. Lock replies `{17:{0:sessionID, 1:serverCommitment(56B)}}`.
3. App computes SPAKE2/P-224 (Google GCD/Weave implementation): `passwordHash = BigInteger(SHA256(pin)[0:28])`; commitment `T = x·G + passwordHash·KM` (56-byte affine x‖y, no prefix); shared key `K = x·(S − passwordHash·KN)`; **pairing-phase AES key = K[0:16]**.
4. Timestamp proof = AES-EAX encrypt of `CBOR({0:unixTimeSec})` under that key with **fixed 1-byte nonce** (`0x00` client→lock, `0x01` lock→client), 96-bit tag.
5. App sends `{1:3, 2:2, 16:{0:sessionID, 1:clientCommitment, 2:encryptedTimestamp}}`.
6. Lock replies `{17:{0:EAX-encrypted blob}}` → decrypt → CBOR `{0:CAT, 1:SAT}`.

### Phase C — secure connection request + SAT extension (session resumption entry point)
1. App sends control header + negotiation map (terminal `20:2` = TOKEN_SHA256 mode) **followed by raw 12-byte clientRandom**.
2. Lock replies with serverRandom; app extracts `satTag` (SAT's 16-byte MAC tag) and **attenuates the SAT** with caveats `[0x14]` (authentication_challenge) and `HMAC-SHA256(key=satTag, CBOR_bstr(0x14 ‖ CBOR_bstr(1 ‖ clientRandom ‖ serverRandom)))`, sends the extended SAT.
3. Lock replies with the matching HMAC for value 2; app verifies, then derives session keys:
   - IKM = `0x02 ‖ clientRandom(12) ‖ serverRandom(12) ‖ satTag(16)` (41 bytes)
   - `HKDF-SHA256.extract(salt = 008A39362204 1F5F0FC75D97 DAEE6E81CBBB 2BC74F9CCC91 E75E77A56B4A 4B05, ikm)`, then `expand(info="session key", 32)`
   - First 16 bytes = **AES-128 session key**, last 16 bytes = **nonce base**.

### Session cipher (both directions)
AES-128-EAX (BouncyCastle, 96-bit tag), no AAD. **Nonce = nonceBase(16) ‖ senderID(1) ‖ counter(3, big-endian)**; phone→lock senderID `0x01`, lock→phone `0x03`, counters from 1 per session. Whole CBOR messages are encrypted before fragmentation; ciphertext reassembled then decrypted.

### Phase D — authorization and access-control claim (pairing completion)
`{1:5, 2:3, 16:{0:1, 1:0, 2:CAT}}` (pairing-mode CAT authorize; post-pairing sessions use `{1:5, 2:1, 16:{0:2,…}}` token mode) → `{1:24, 2:4}` (claim) → lock returns new CAT → `{1:25, 2:5, 16:{0:CAT}}` (claim complete). Housekeeping: timezone (trait 5 prop 20), DST times, read serial/model/firmware. The app stores `{sat, cat, userId, model, serial, mac, firmware}`; thereafter only Phase C is needed.

### Macaroon wire format
CBOR `bstr( array(N) bstr(caveat₁)…bstr(caveat_N) bstr(mac_tag) )`. Tag = HMAC-SHA256 chained over caveats, **truncated to 16 bytes**. Attenuation = append caveat + recompute tag.

**Security notes:** (a) the entire trust root is the printed programming code — treat it as a physical secret; (b) per-session keys are properly ephemeral (fresh randoms, HKDF); (c) the static pairing-phase nonces (0x00/0x01) mean pairing traffic has no replay protection beyond the timestamp — pair away from adversaries, but that's a one-time 30-second window; (d) SAT/CAT are bearer tokens — a dumped app database plus BLE range = control without the programming code.

---

## 6. Command layer (CBOR "Privet" RPC)

Envelope: request `{1:apiId, 2:requestTypeId, 16:{trait, property, data}}`; success result at key `17` (often nested at 17 again); error code at `3 → 4`. apiIds: 2=pairing start, 3=pairing confirm, 5=auth(CAT), 6=state query, 8=trait/property RPC, 24=claim, 25=claim confirm. Key 2 is a fixed-per-command constant (1=DST write, 2=check/FDR/delete, 3=pairing-CAT/list-check/history-read/state, 4=reads/WiFi/claim, 5=deleteAll/claim-confirm/JITR, 7=writes).

Traits: 1=LockData, 3=History/DeviceMgmt, 4=AccessCodes, 5=LockConfig, 6=WiFi.

| Operation | Wire format |
|---|---|
| Lock / Unlock | `{1:8,2:7,16:{0:1,1:0,2:{0:stateOrdinal,1:userId(8B BE)}}}` |
| Lock state | `{1:6,2:3}` → keys 0=status, 12=batteryState, 14=alarmEnabled, 21=batteryLevel, 25=doorState |
| Read info | `{1:8,2:4,16:{0:1,1:P}}` P: 2=mfr, 3=model, 4=serial, 5=main FW, 7=time, 12=battery, 15=ext FW |
| Set time | saveData trait 1 prop 6 (unix secs) |
| Read settings | trait 5: 3=beeper, 5=autoLockTime, 9=alarmMode, 11=alarmSensitivity, 13=lockAndLeave, 15=codeLength, 21=tz, 27=opMode |
| Write settings | trait 5: 2=beeper, 4=autoLockTime, 8=alarmMode, 10=alarmSensitivity, 12=lockAndLeave |
| Set timezone / DST | trait 5 prop 20 (minutes) / `{1:8,2:1,16:{0:5,1:18,2:{0:1,1:start,2:end}}}` |
| Enable simultaneous (Matter) mode | trait 5 prop 26 = 1 |
| Set access-code length | `{1:8,2:2,16:{0:5,1:14,2:{0:len}}}` |
| Add/update access code | `{1:8,2:3,16:{0:4,1:(0=add,4=update),2:{0:userUuid(8B BE),1:name,2:code,3:sched1,4:sched2,5:blocked,6:startEpoch,7:endEpoch}}}` |
| Delete code / delete all | `{1:8,2:2,16:{0:4,1:1,2:{2:code}}}` / `{1:8,2:5,16:{0:4,1:2}}` |
| List codes | check `{1:8,2:3,16:{0:4,1:6,2:{0:0}}}` + read `{1:8,2:4,16:{0:4,1:5}}` (moreAvailable key 0x0A) |
| History logs | check `{1:8,2:2,16:{0:3,1:0,2:{0:0}}}` + read `{1:8,2:3,16:{0:3,1:batchSize}}` |
| Factory reset | `{1:8,2:2,16:{0:3,1:3}}` |
| WiFi credentials | `{1:8,2:4,16:{0:6,1:0,2:{0:ssid,1:password,2:security}}}` |
| WiFi JITR payload0 | `{1:8,2:4,16:{0:6,1:2,2:{0:payload0Bytes}}}` |
| JITR status | `{1:8,2:5,16:{0:6,1:4}}` → 0..6 (stopped/started/success/AP error/host error/IP acquired/wrong creds) |
| Firmware OTA | separate GATT profile (§4) |

Enums: lockState 0=unlocked, 1=locked, 2=jammed, 3=unknown, 4=motorJammed, 5=passage, 6=deadlocked. doorState 0=unknown, 1=open, 2=closed, 3=faulty. opMode 0=Schlage BLE only, 1=simultaneous (BLE+Matter).

---

## 7. WiFi: commissioning vs runtime

- **Commissioning is BLE-driven.** In 3.6.0 the app itself encrypted the WiFi payload: `key = SHA-256(secret + "|" + id[6:])`, AES/CBC/NoPadding with a **zero IV**, over `be64(counter) ‖ JSON({ssid,password})` zero-padded to 16 (`api/bridge/commission/model/WifiPayload.java`). In 6.3.1 this moved server-side: the encrypted "payload0" (JITR cert blob) is fetched from `factory.allegion.yonomi.cloud` (`GET …payload0?deviceType=…&physicalId=<SERIAL>`) and pushed to the lock over BLE trait 6 prop 2. So **onboarding a lock to WiFi requires Schlage's cloud once** (to mint its AWS IoT identity); after that, BLE remains fully functional cloud-free.
- **BR400 WiFi adapter (legacy Sense):** commissioned over its own AP via local REST (`POST v2/prov/registration`, `GET v1/prov/networks`, `GET bridge/ble/scan`, `GET bridge/v1/commission/status`, `GET bridge/info`), then rediscovered by mDNS — commissioning-only, not a runtime control channel.
- **Runtime local WiFi control: none.** Exhaustive search of both APKs found no socket/HTTP/mDNS runtime path to any lock. Path selection (`SenseDeviceServiceProvider`): no network / guest user / failed cloud session → **BLE**; WiFi-mode locks → cloud REST+MQTT. Identical command semantics on both paths.

---

## 8. How to build a no-cloud local client

1. **Prereqs:** physical access to the lock's programming code; BLE proximity; lock in Schlage (not HomeKit) mode — or switchable via commissioning.
2. **Fastest route:** the Go library `golang.betakappaphi.com/schlage-uweave` — independently validated against the APK extraction in this report (§5–§6). It already implements the transport, SPAKE pairing, macaroons, session crypto, and the full command map.
3. **DIY (e.g., Python + bleak):** implement §4 fragmentation, Phase A/C handshake (skip B if you have valid SAT/CAT… which you only get from Phase B pairing), AES-EAX with the nonce construction in §5, HKDF with the recovered salt constant, and the CBOR tables in §6. All constants needed are in this report.
4. **One active BLE session at a time** — while your client is connected, the Schlage app falls back to cloud; cloud commands and local BLE commands are semantically identical, so state stays consistent.
5. **What you still can't do locally:** mint the lock's cloud identity (payload0/JITR), get firmware binaries' metadata, manage app invites/users, or receive out-of-BLE-range push. A Home Assistant local integration would pair once (programming code), then poll/push over BLE using the §6 tables — no yonomi dependency for day-to-day lock/unlock/codes/logs.

## 9. Caveats and open items

- The connection-negotiation CBOR map's exact bytes were verified semantically but not byte-for-byte (built through obfuscated helpers; the Go library's uint16-BE description is wire-equivalent). The 12-byte clientRandom trailer is byte-verified.
- Newer firmware ("Arrive"/WKD) may skip the ConnectionRequest/Confirm step (`ConnectDirect` in the Go lib); the 6.3.1 app always performs it on the Sense/Denali path.
- HomeKit-mode pairing (HAP) is Apple's documented protocol (SRP setup, Ed25519 identities, Curve25519 STS, ChaCha20-Poly1305 sessions) and was not re-derived here.
- 6.3.1 is commercially shielded (native string decryption in `libh0.so`, encrypted assets); all protocol-relevant Java under `com.allegion.leopard.*` was nonetheless unobfuscated and fully readable.
- APK provenance: apk.gold mirrors (3.6.0 and 6.3.1, md5-verified against mirror listings). Decompiled with jadx 1.5.1 / apktool 2.12.0. The standalone "Schlage Sense" app is discontinued (merged into Schlage Home); 3.6.0 covers the Sense stack.

## 10. Artifacts

- `19fc081d-82a2-8df8-8000-0f669db8b393/schlage/PROTOCOL_NOTES.md` — fully cited protocol extraction (class/line references)
- `…/schlage/dumps/cbor_command_table.md`, `sense_gatt_profile.json`, `firmware_gatt_profile.json`, `sense_gatt_profile-3.6.0.json`
- `…/schlage/INVENTORY.md`, `uuids_631.txt`, `interesting_classes_631.txt`
- `…/schlage/key-sources-6.3.1/`, `key-sources-3.6.0/` — extracted protocol source files
- `…/schlage/decomp-6.3.1-allegion/`, `decomp-3.6.0/` — full `com.allegion` source subtrees (5,608 files)

---

### Appendix A — Prior-art sources (cloud ecosystem, HomeKit, community RE)

- pyschlage (dknowles2) — the reference cloud client, built partly from the same APK; now backing the official Home Assistant `schlage` integration. github.com/dknowles2/pyschlage
- HA community thread "Schlage Encode Wifi" (108826) — multi-year RE history: Cognito auth (punk-kaos), MQTT/WSS details (dknowles2), zeroconf capture of Encode Plus `_hap._udp` (port 5683, `md=be499WB`), unimplemented DNS-redirect local-mock idea.
- FCC ID XPB-JACKALOPE — Encode Plus internals (EFR32MG12 BLE/Thread module, NXP NFC w/ ECP).
- Schlage support docs — BLE fallback mode ("app switches to BLE mode when cloud is unreachable"), Bluetooth-only setup for BE489/BE499, Sense↔HomeKit pairing exclusivity.
- Apple Platform Security — HomeKit/HAP cryptographic design.
- `golang.betakappaphi.com/schlage-uweave` — public Go reimplementation of the BLE protocol, used as the cross-validation oracle.
