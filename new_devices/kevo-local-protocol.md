# Kwikset Kevo — Local Protocol Reverse-Engineering Report

**Scope:** everything needed to operate a Kevo lock *without the UniKey/Kwikset cloud*, recovered from public research + decompilation of the Android app (`com.unikey.kevo`).
**Primary evidence:** `Kevo-3.1.1.33967p.apk` (md5 `cf92c4dc86795cbc9a765b7838c186bb`, signature SHA1 `04505561AF11DF80B14BE85B1E13B7593D2A95AB` — matches the published mirror metadata; unobfuscated code) cross-checked against `Kevo-2.9.1.21765p.apk` (md5 `864bd6f5021e9167d5276810a1c3beab`, the exact version NCC Group tested). Protocol constants are identical in both.
**Date:** 2026-08-02.

---

## 0. TL;DR

1. **The Kevo cloud is already dead** (app + portal shut down 2025-11-14 by ASSA ABLOY/Kwikset). Local BLE is now the *only* working control path besides the physical key and key fobs — which also proves the lock↔fob BLE auth is fully self-contained.
2. **The complete phone-side BLE protocol has been recovered from the APK** (previously undocumented anywhere public): one GATT service with 4 characteristics, inverted roles (**lock = BLE central**, phone = peripheral/GATT server), challenge-response using **HMAC-SHA256 over a shared secret derived from X25519 ECDH**, and a TLV "certificate" channel for enrollment/settings/history/firmware.
3. **All session crypto is 100% pure Java** (JCA + vendored Tink X25519/Ed25519) — no native code, fully extractable and reimplementable.
4. **There is no WiFi/local-LAN protocol.** The Kevo Plus gateway is *wired Ethernet + BLE only* and has **no LAN API used by the app** — every gateway command transits the UniKey cloud (REST + WebSocket). First-time gateway setup is **BLE**, not LAN. The only unexplored local surface is the gateway's own debug ports (499/11000 per vendor docs, never publicly scanned).
5. **Practical no-cloud path:** run a Linux box (BlueZ) as a BLE peripheral impersonating the phone — advertisement format, GATT server, state machines, and crypto are all documented here. Credentials come from either (a) extracting the per-lock shared secret + device cert from the phone, or (b) doing a fresh tap-to-enroll yourself (the enroll exchange is lock↔phone only).
6. Remaining unknowns (lock-side firmware behavior, certificate field names, LIC/time-sync layout) require one over-the-air capture; the app side is fully mapped (§6 lists exactly what to sniff).

---

## 1. Why now: the cloud is gone

- ASSA ABLOY (Kwikset/Weiser) **shut down the Kevo app and web portal on 2025-11-14**. Remote/app control officially ceased; physical key and key fobs still work. UniKey (a separate company) has offered customers continued service.
  Sources: kwikset.com/support ("What does the Kevo app shutdown mean…"), ca.weiserlock.com ("Kevo app shutdown").
- Every existing community integration (pykevoplus, aiokevoplus, home-assistant-kevo, kevo_ex, homebridge-kevo, …) is a **cloud API client** — none ever spoke BLE to the lock or IP to the gateway. HA forum consensus (2021): "There is no way to control the Kevo lock natively/locally even though it works over Bluetooth."
- **No public documentation of the Kevo GATT profile or BLE handshake existed** (confirmed by targeted search) — this report fills that gap.

## 2. System architecture (as built)

```
            ┌────────────┐   BLE (lock is CENTRAL)   ┌──────────────┐
            │ Kevo lock  │ ◄────────────────────────► │ Phone / fob  │
            │ (GATT      │   phone is PERIPHERAL +    │ (peripheral, │
            │  client)   │   GATT server + advertiser │ GATT server) │
            └─────┬──────┘                            └──────┬───────┘
                  │ BLE                                      │ HTTPS/WSS
            ┌─────┴──────┐                            ┌──────▼───────┐
            │ Kevo Plus  │  wired Ethernet to router  │ UniKey cloud │
            │ gateway    │ ─────────────────────────► │ resi-prd-api │
            │ ("RPU")    │   (no WiFi, no LAN API)    │ .unikey.com  │
            └────────────┘                            └──────────────┘
```

- **Inverted BLE roles** (confirmed in code and by NCC Group): the **lock is the BLE central** that scans, connects, and issues GATT reads/writes; the **phone/fob is the peripheral** that advertises and hosts the single GATT service. This is why Android support needed Android 5.0+ (first release with peripheral mode). The phone *also* scans for the lock's adverts (presence/proximity), but all bulk data flows over the phone-hosted service.
- **No BLE link-layer encryption/pairing** (NCC Group): security is entirely at the application layer. Passive sniffing of the (application-layer-protected) traffic is trivially possible; GATT-level relay works.
- **Proximity / touch-to-open**: lock verifies an authorized device is outside and near before acting on touch; two chip antennas ("Latch Side"/"Key Side", FCC test report for FCC ID NUL-MK1) implement the patented inside/outside discrimination (US9218696). Relay resistance is behavioral (accelerometer-based TTO disable after 30 s stationary, optional 2FA), not cryptographic — NCC's link-layer relay defeats TTO (CVSS 6.8, all Kevo versions).
- Lock hardware (FCC NUL-MK1, gen-1, model 925-GED1500-MK1): BLE single-mode 2402–2480 MHz, UniKey in-house radio module "HHI BLE MODULE 450-00022-001" (SoC unidentified — 2013-era, likely TI CC254x or Nordic nRF51822 class). Gateway (FCC NUL-924, "Router Plugin Unit", model 924-GED1900-RPU): BLE + RJ45 Ethernet, USB power.

## 3. The local BLE protocol (from decompilation)

*Source: `com.unikey.sdk.support.*`, `com.unikey.sdk.residential.*`, `com.unikey.kevo.*` in Kevo-3.1.1. Every claim below cites the implementing class in the full findings file; this section is the actionable spec.*

### 3.1 GATT profile (hosted by the PHONE; the lock is the client)

One 128-bit service, four 16-bit characteristics in the Bluetooth base UUID `0000xxxx-0000-1000-8000-00805F9B34FB`
(`BluetoothProductionComponent$Module.produceGattServiceUuids`, `BluetoothGattCharacteristics.<clinit>`, `MakeServicesKt.makeDefaultCharacteristics`):

| Characteristic | UUID | Props | Role |
|---|---|---|---|
| Service | **`86130247-E942-4FE5-AA46-E30768A0C1B0`** | — | the only service |
| `UNIKEY_CHAR_COMMAND` | **0x0989** | READ | lock **reads** the phone's pending 4-byte command |
| `UNIKEY_CHAR_DATA_STREAM` | **0x0979** | READ+WRITE | bulk data: UUIDs, nonces, HMACs, firmware chunks |
| `UNIKEY_CHAR_STATUS` | **0x0999** | WRITE | lock **writes** flow-control/status messages (dispatch on byte[3]) |
| `UNIKEY_CHAR_CERTIFICATE` | **0x0959** | READ+WRITE | UniKey TLV "certificate" exchange (enroll, settings, history, firmware, result codes) |

Notable: **no NOTIFY characteristics** — phone→lock data rides GATT *read responses*; the lock polls. (`531527c1-…` in the strings is cloud-config, not GATT; a `0x0969` char is constructed and discarded — dead code.)

### 3.2 Advertisements

**Phone → air** (`BluetoothDefaultAdvertiseDataBuilder`): manufacturer data, **company ID 0x015E (UniKey)**; payload = TLV-ish records: default `[0x05 + 6 fresh random bytes]` (anti-replay freshness beacon, new randomness per advert); optional `[0x04, antennaOffset]` (RSSI calibration); slow mode `[0x01,0x14,0,0,0]`. Legacy connectable advertising, **250 ms interval** (400×0.625 ms), lowest TX power.

**Lock → air** (parsed by `BluetoothAdvertisementParser`, filtered by `BluetoothService.makeFilterBuilders`): manufacturer data with the **per-lock 16-byte UUID** (= the lockId the cloud API uses):
- Format 2 (21 B): `[0x02][16B UUID BE][u32 LE]`, company **0x015E**;
- Format 1 legacy (17 B): `[16B UUID BE][u8]`, company **0x5E01** (the same ID byte-swapped on the wire — a firmware quirk; the app filters for both).
- Admin/enroll scan: wildcard filter on company 0x015E, finds any lock.
- Trailing u32/u8 semantics unknown (status/counter?) — capture item.

### 3.3 Normal session: touch-to-open / lock / unlock

State machine: `DeviceConnectionProtocolMachineImpl` (+ `DeviceChallengeResponseProtocolMachineImpl`), byte logic in `…ProtocolMachineDelegateImpl`. After GATT connect:

1. Lock **writes STATUS** `[0,0,0, 0x01]` — "challenge-UUID begin".
2. Lock **reads DATA_STREAM** ← phone's 16-byte mobile-device UUID (BE).
3. Lock **writes DATA_STREAM** → its 16-byte lock UUID (fragment-tolerant concatenation).
4. Lock **writes STATUS** `[1,x,x, 0x01]` — complete; phone resolves/creates the **shared secret** for that lock UUID (cached in SharedPreferences; else KeyPresent flow §3.5b).
5. Lock **reads COMMAND** ← phone's 4-byte pending command `[0,0,0,op]` (opcodes §3.4).
6. Lock **writes STATUS** `[x,x,lockState, 0x02]` — nonce challenge start.
7. Lock **writes DATA_STREAM** → nonce (32 B).
8. Lock **writes STATUS** `[…, 0x03]` — "give HMAC"; phone computes:
   **`resp = HMAC-SHA256(key = sharedSecret, msg = nonce XOR cmd)`** — the 4-byte command XORed into nonce bytes 0..3 (`calculateHmac`, JCA `HmacSHA256`).
9. Lock **reads DATA_STREAM** ← 32-byte HMAC.
10. Lock **writes STATUS** `[result, battery, x, 0x04]` — verdict: `0x01` = accepted (battery level in byte[1]); `0xF0` = denied **and the phone wipes its cached secret** (forces KeyPresent next time).

Other STATUS byte[3] types: `0x9A` = lock firmware version (`[patch,minor,major]`); `0x9B` = firmware-upgrade marker; `0x12` = bolt-position query family; `0x15` = enroll begin result; `0x30` = key-present begin.

### 3.4 Command opcodes (last byte of the 4-byte COMMAND value)

| Opcode | Meaning | Source |
|---|---|---|
| 0x10 | **Toggle** lock/unlock (touch-to-open) | `KevoLockToggleCommand.getType()` |
| 0x12 | Bolt position / status query | `LocalCommandWorker` |
| 0x13 | **Lock** | `LocalCommandWorker` |
| 0x14 | **Unlock** | `LocalCommandWorker` |
| 0x15 | Tap-to-enroll (locks *and* Kevo Plus gateway) | `…DelegateImpl.tapToEnrollCommand`, `GatewaySetupActivity` |
| 0x19 | Lock history request | `LockHistoryCommand` |
| 0x9B | Firmware upgrade begin (command = `[ver LE…, 0x9B]`) | `…DelegateImpl.firmwareUpgradeCommand` |
| 0x00 / 0xFF | null command / dequeue sentinel | delegates |

Idle default pending set = `[0x10, 0x19]` (toggle + history upload). Battery arrives in the 0x04 STATUS; no separate battery opcode. Result codes (CERTIFICATE-char result certs, field 0xBD): `1=SUCCESS, 2=CONTINUE, 3=UNINITIALIZED, 4=COMMAND_TIMEOUT, 0=FAILURE, -1=FAILURE_SLEEPING, -3=FAILURE_BAD_UDATA, -4=FAILURE_GATT, -5=FAILURE_NO_OWNER, -6=FAILURE_RESOURCES, -7=PROTOCOL_ERROR, -8=FAILURE_DOOR_OPEN, -9=FAILURE_IR, -10=FAILURE_BAD_DATA, -11=FAILURE_HAS_OWNER, -12=FAILURE_LOW_BATT, -13=INVALID_CERTIFICATE, -14=FAILURE_RANGE, -15=FAILURE_INSIDE, -16=UNAUTHORIZED`.

### 3.5 Credentials & enrollment

**Crypto primitives** (`com.unikey.sdk.support.crypto.*` + vendored `tink.*`): X25519 ECDH, Ed25519 signatures, HMAC-SHA256, SHA-256, AES-128-CBC/NoPadding (IV prefixed, random per message), CRC-16/BUYPASS (poly 0x8005).

**Shared-secret derivation** (`Secret$Builder`):
- Enroll/first-contact: `secret = HMAC-SHA256(key = X25519(phonePriv, lockPub_fromCertField_0x35), msg = lockNonce ‖ phoneNonce)` (both nonces exactly 32 B).
- Key-present (server-provisioned): phone AES-128-CBC-decrypts the permission's `secretBetweenMobileDeviceAndHardwareEncryptedForMobileDevice` with key = `X25519(serverPub_fromWebServerCert_0x35, phonePriv)`.

**Tap-to-enroll** (`DeviceTapToEnrollProtocolMachineImpl`) — creates a brand-new authorized device, lock↔phone only:

| Phone cmd byte | Step | Direction | Lock ack (STATUS b[3]) |
|---|---|---|---|
| 0x29 | device public cert | lock reads phone | 0x21/0x22, validity 0x24 |
| 0x28 | server public cert | lock reads phone | 0x21/0x22 |
| 0x40 | phone 32 B nonce | lock reads | 0x40 |
| 0x21 | lock hardware cert | lock writes | 0x21 |
| 0x22 | lock manufacturer cert chain | lock writes | 0x22 |
| 0x43 | lock 32 B nonce | lock writes | 0x42 |
| 0x60 | **session certificate** | lock writes | 0x60 → enroll success |

The phone's own cert is generated once (random UUID + 32 B seed → X25519 + Ed25519 keypairs) as a UniKey TLV cert: fields 0x30=role(6), 0x32=UUID, 0x35=X25519 pub, 0x36=Ed25519 pub, 0xB7=expiry, 0x14=issued-at, 0x11=cert type(1), 0x10=0x30, … TLV = `[field:1][len:2 LE][value]`. On success the app registers the eKey to the cloud — **required for the official flow, irrelevant for a pure-local controller** (the session cert is written by the lock during enroll itself).

**Key-present flow** (`DeviceKeyPresentProtocolMachineImpl`): for a known lock without cached secret — phone presents device cert + permission cert + server-encrypted secret; lock verdicts via STATUS 0x24/0x31/0x38/0x40/0x42; on commit phone caches the secret.

**Phone-side storage** (what to extract for local control):
- Shared secrets per lock UUID (base64): SharedPreferences via `SdkDataStore` (pref key contains `device_shared_secret`).
- Device identity keys/certs: **sqlcipher DB `kevo`**, table `Certificates(PrivateKey, PrivateSigningKey, PublicSigningKey, SignedPublicCertificate, UUID, DeviceName, Expiry, DeviceType)`. DB passphrase = account DB key + salt (`PasswordProvider`); the account key is wrapped by Android-Keystore RSA alias `"kevo"` (RSA/ECB/PKCS1Padding) — extraction needs the phone (keystore) or an already-decrypted DB.
- Server public cert: SharedPreferences `SERVER_PUBLIC_CERT_KEY`.

### 3.6 The "UPC" certificate channel (CERTIFICATE characteristic)

Runs in parallel with the command channel (`Ble_serverMachineImpl`): the lock writes query certs, reads signed response certs. DIQ (type 0x70: lock UUID field 0x72, lock nonce field 23, hardware cert field 0x91) → phone answers signed cert with pending command (field 0xB0), its nonce (23), UUID (49). All post-auth certs are **HMAC-signed** (`CertificateSigner`): field **34 (0x22)** = `HMAC-SHA256(sharedSecret, serializedCert XOR nonce)`; nonces rotate every connection → captured certs don't replay. Result certs (field 0xBD result code) cover lock action, status query, door position, history, firmware, re-key. Device settings (DSQ/DSW) and server-verification (SVQ/SVW) states ride the same channel.

### 3.7 Firmware update over BLE

Two flows, triggered by command 0x9B after a cloud version check:
- Legacy DATA_STREAM: header → ack 0x97; 256-B chunks → ack 0x98 with next offset (u24 LE); per-block `[len u16][CRC16/BUYPASS]` → ack 0x9D; 0x9E = image verified.
- UPC: chunks of 900 B inside signed certs; next offset in result field 0x9B.
Firmware image signing/encryption is not parsed in the app (opaque blob) — lock-side item.

### 3.8 Time sync (needed for full fidelity)

`TimeSyncService`: cloud server timing cert is relayed into the lock during the UPC exchange; the lock returns a **LockInformationCertificate (LIC)**. A local controller should parse the LIC and supply a plausibly-fresh timing cert, or scheduled eKeys and event timestamps degrade. LIC field layout is lock/cert-side — capture item.

## 4. WiFi / Kevo Plus gateway: there is no local network protocol

Full-DEX sweep (every method's strings/invokes/type refs, cross-verified with decompilation):

- **No LAN code anywhere**: zero `DatagramSocket`/`MulticastSocket`/`NsdManager`/mDNS/UDP broadcast/hardcoded IPs; no `WifiManager`/Soft-AP. The only raw sockets are OkHttp internals (cloud HTTPS). The gateway is **wired Ethernet + BLE only** — there is no WiFi in the system at all.
- **All gateway traffic transits cloud**: REST `https://resi-prd-api.unikey.com/api/<ver>/…` and WebSocket `wss://ws.unikey.com/<ver>/mobile/{userId}` (URL built by `replace("api.unikey.com/api","ws.unikey.com")`). Remote lock/unlock: authenticated `PUT /Users/{userId}/Locks/{lockId}/Commands`, body `{"command":<int>,"deviceStates":[{type,data(base64)}]}`; `GatewayCommandType`: LOCK=1, UNLOCK=2, BOLT_POSITION_QUERY=4, DEVICE_STATE_UPDATE=5, DEVICE_STATE_QUERY=6, TIME_SYNC=8, QUERY_HISTORY=16. Server emits literal `504 - Gateway timeout` when the gateway doesn't relay — confirming the app→cloud→gateway path.
- **Gateway provisioning is BLE, not LAN**: the phone enrolls the RPU *exactly like a lock* (same tap-to-enroll state machine, hardware type 19, product descriptor "RPU1"), injecting the cloud **server public certificate** during enroll, then registers it with one authenticated `PUT /Rpus/{uuid}` carrying the BLE **session certificate**. The vendor's "direct connection during first setup" = BLE. Afterwards the gateway↔lock bond is made by the gateway itself ([inference] it scans/pairs autonomously with its enrolled credentials and reports to cloud; the phone only observes `hasRPU` in cloud lock JSON).
- **Debug ports 499/11000** (vendor-documented "Local Debug") and ports 8100/8301/13252 appear **nowhere** in the app — if open, they're gateway-side listeners nobody has publicly investigated. With the cloud off, nmap + banner-grab on those ports is the most interesting gateway-side experiment left.

## 5. Path to no-cloud operation (practical roadmap)

**What a local controller must implement** (all documented above, all pure software):
1. BLE **peripheral** role (Linux BlueZ supports this): advertise company 0x015E with the `[0x05 + 6 random]` payload at ~250 ms.
2. GATT **server** with service `86130247-…` and the 4 characteristics, wired to the state machines of §3.3/§3.6 (the lock drives via reads/writes; your code answers).
3. Crypto: X25519, Ed25519 (for cert gen), HMAC-SHA256, SHA-256, AES-128-CBC, CRC16/0x8005 — all standard library material.
4. Credentials: either
   - **(a) extract** the per-lock shared secret + your device cert from a phone that was previously paired (SharedPreferences + sqlcipher `kevo` DB; needs keystore unwrap — do it while a working phone/app still exists, or via the UniKey service if they truly revive it), or
   - **(b) self-enroll**: implement tap-to-enroll (§3.5) — the exchange is purely lock↔phone; your controller becomes a new "device" with its own generated cert. Cloud registration after enroll is *not* needed for local operation (caveat: confirm via capture that the lock doesn't later de-auth devices that never appear in cloud — the 0xF0 "wipe" verdict exists, and historically the app erased lock lists when it couldn't phone home; whether the *lock* prunes non-cloud keys is unknown).
5. Optional fidelity: LIC/time-sync handling (§3.8), history pull (0x19) if you want audit logs locally.

**Security notes for your own deployment**: the protocol's challenge-response is solid (rotating nonces, HMAC-signed certs, ECDH-derived secrets), but there is **no link-layer encryption and no replay-protected channel binding to distance** — anyone in radio range can passively observe ciphertext, and NCC demonstrated TTO relay. Your controller gains TTO-level trust; treat its BLE credential store accordingly.

## 6. What still needs an over-the-air capture (or lock firmware)

1. Lock-side behavior: exact nonce lengths, DATA_STREAM/CERTIFICATE fragmentation, session-cert construction, internal secret derivation (assumed symmetric).
2. TLV certificate field names (compile-time constants were inlined/stripped; numeric tags recovered from use sites).
3. LIC layout / timing-cert freshness rules (time sync).
4. Semantics of the lock advert's trailing u32/u8.
5. DBU client challenge sub-flow bytes (secondary auth after bolt-position queries).
6. Firmware image format/signing.
7. Confirmation the lock accepts a self-enrolled device long-term without cloud (§5-4b caveat).
8. Gateway-side: what's actually listening on TCP 499/11000 (and 8100/8301/13252); whether the RPU's "Local Debug" allows any useful local control.

**Recommended captures** (Sniffle on a TI CC1352/CC2652 is ideal; no link-layer encryption so any LE sniffer works): one touch-to-open, one app-driven lock+unlock, one tap-to-enroll, one firmware update, one gateway-first-boot. No link-layer encryption means the application-layer messages above should be directly visible and checkable against §3.

## 7. Methodology & evidence

- APKs acquired from apk.gold mirror, md5/signature-verified against published metadata (both signed by the same UniKey cert SHA1 `04505561…`).
- Decompilation: androguard (DAD pseudocode) + custom DEX bytecode scanner; full-dex sweeps back every "absent" claim about LAN code. 741 class dumps + targeted smali disassemblies preserved.
- Working files: `/mnt/agents/work/kevo/` — `BLE_PROTOCOL_FINDINGS.md` (full citations), `BLE_REMAINING_QUESTIONS.md`, `gw/GATEWAY_FINDINGS.md` (+ `full1.txt`/`full2.txt` sweeps, `decompiled.txt`), `notes/src/` (class dumps).
- Prior public research cross-validated: NCC Group advisory (2022, relay attack; no link-layer encryption), DEF CON 24 Rose/Ramsey (2016: Kevo one of 4 locks *not* cryptographically broken), UniKey patent family US9336637/US9057210/US9218696 (functional handshake only — no wire formats), FCC filings NUL-MK1 / NUL-924 (hardware), Berkeley ASIACCS 2016 "Smart Locks" paper.

## 8. Key sources

- NCC Group advisory: nccgroup.com/research/technical-advisory-kwiksetweiser-ble-proximity-authentication-in-kevo-smart-locks-vulnerable-to-relay-attacks/
- DEF CON 24 "Picking Bluetooth Low Energy Locks" (media.defcon.org)
- Kwikset/Weiser shutdown notices (kwikset.com, ca.weiserlock.com, Nov 2025)
- UniKey patents: US9057210, US9218696, US9336637, US9196104, US9613478, US9852561, US9501883
- FCC: fccid.io/NUL-MK1 (lock), fcc.report/FCC-ID/nul924 (gateway)
- Cloud API references (historical): github.com/dcmeglio/pykevoplus (aiokevoplus), Moosieus/kevo_ex
