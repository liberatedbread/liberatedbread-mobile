# Kwikset Kevo

> **Status**: In Progress (phone-side protocol complete; no over-the-air capture yet)
> **Protocol**: BLE (inverted roles — the lock is the central)
> **Manufacturer**: Kwikset / ASSA ABLOY (UniKey Technologies platform)
> **Manufacturer Status**: Shutdown (app + portal killed 2025-11-14)

## Overview

The Kevo is a touch-to-open smart deadbolt built on UniKey's BLE platform,
sold under Kwikset, Weiser and Baldwin (Evolved) badges. On **2025-11-14**
ASSA ABLOY shut down the Kevo app and web portal
([Kwikset support notice](https://www.kwikset.com/support/answers/what-does-the-kevo-app-shutdown-mean-to-my-kevo-door-lock),
[Weiser notice](https://ca.weiserlock.com/support/troubleshooting/support-articles/kevo-app-shutdown)).
Remote control, eKey management and the Kevo Plus gateway relay all died with
it. The physical key and key fobs still work — which proves the lock's BLE
authentication is fully self-contained — so **local BLE is the only remaining
electronic control path**.

The complete phone-side BLE protocol was recovered from the Android app
(`com.unikey.kevo` v3.1.1.33967p, unobfuscated) and re-verified for this
document. No public documentation of the Kevo GATT profile existed before;
every prior community integration (pykevoplus, aiokevoplus, kevo_ex, …) was a
cloud API client.

### Inverted BLE roles — read this first

The **lock is the BLE central and GATT client**: it scans, connects, and
drives every session with reads and writes. The **phone/fob/controller is the
peripheral**: it advertises and *hosts* the single GATT service. There are no
NOTIFY characteristics — the lock polls, and phone-to-lock data rides GATT
read responses. A local controller must run as a BLE peripheral with a GATT
server (Linux BlueZ can do this); the usual "scan, connect, write to a
characteristic" client pattern does not apply.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Lock (gen-1): 925-GED1500-MK1; gateway: 924-GED1900-RPU |
| Chipset | UniKey in-house "HHI BLE MODULE 450-00022-001" (SoC unidentified; 2013-era, TI CC254x / Nordic nRF51822 class) |
| Radio | BLE single-mode 2402–2480 MHz (lock); gateway adds wired Ethernet — **no WiFi anywhere in the system** |
| FCC ID | Lock: [NUL-MK1](https://fccid.io/NUL-MK1); Kevo Plus gateway ("Router Plugin Unit"): [NUL-924](https://fcc.report/FCC-ID/nul924) |

The lock has two chip antennas ("Latch Side" / "Key Side") implementing the
patented inside/outside discrimination (US9218696) behind touch-to-open.

## Initial Setup

The lock only answers HMAC challenge-responses keyed by a per-lock shared
secret, and that secret only comes into existence during enrollment — so
provisioning is genuinely required.

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `ble_provisioning` (tap-to-enroll) — or credential extraction from a previously paired phone |
| Setup AP / advertised name | None; the *controller* advertises company ID `0x015E` and the lock connects to it |
| Passphrase protection | not_applicable (no WiFi; enrollment is certificate-based) |
| Confidence | medium (full exchange read from the decompiled app; not run against hardware here) |

**Tap-to-enroll** (command opcode `0x15`): the controller advertises and hosts
the GATT service; the user puts the lock in enroll mode physically; the lock
connects and drives a certificate+nonce exchange (device cert `0x29`, server
cert `0x28`, phone nonce `0x40`, lock hardware cert `0x21`, manufacturer chain
`0x22`, lock nonce `0x43`, session certificate `0x60`). Both sides then derive
the shared secret (see below). The official app registers the new eKey to the
cloud afterwards, but that step is irrelevant for local operation — caveat: it
is **unknown** whether the lock later de-auths devices that never appear in
the cloud (the `0xF0` "deny and wipe" verdict exists), so keep your derived
secret and certs safe.

**Credential extraction** (the other route): per-lock shared secrets live in
the app's SharedPreferences (base64, key contains `device_shared_secret`);
device identity keys/certs live in the sqlcipher database `kevo`, whose
passphrase is wrapped by an Android-Keystore RSA key — extraction needs the
phone itself, so do it while a working paired phone still exists.

**Factory reset**: exists (vendor documents holding the interior "A" button
~20 s on 2nd-gen; 1st-gen differs) and clears enrolled devices. The exact
per-generation procedure is not established here — consult Kwikset's
documentation; a guessed sequence on a door lock can lock you out.

**Rebinding**: a previously enrolled client rejoins with its cached shared
secret (or re-runs the key-present flow with its certificates). A reset is
only needed to revoke a lost credential.

## Protocol Summary

### Advertisements

**Controller → air**: legacy-connectable, ~250 ms interval, lowest TX power,
manufacturer data company ID **`0x015E` (UniKey)**, payload of TLV-ish
records: default `[0x05 + 6 fresh random bytes]` (anti-replay freshness
beacon, re-randomised per advert), optional `[0x04, antennaOffset]`, slow mode
`[0x01,0x14,0,0,0]`.

**Lock → air**: manufacturer data carrying the per-lock 16-byte UUID (the
cloud API's lockId). Format 2 (21 B): `[0x02][16B UUID BE][u32 LE]` under
company `0x015E`; legacy format 1 (17 B): `[16B UUID][u8]` under company
`0x5E01` — the same ID byte-swapped, a firmware quirk; filter for both. A
wildcard `0x015E` filter finds any lock. The trailing u32/u8 is the lock's
**state-change sequence number**: the app stages it per lock and only treats
an advert as "new data available" when it differs from the last committed
value (committing on connect; 0 resets the baseline). The same counter comes
back in the result certificate (LIC field `0xBC`, u32 LE) after lock actions
and status queries.

### GATT profile (hosted by the controller; the lock is the client)

| UUID | Name | Props (phone side) | Role |
|------|------|--------------------|------|
| `86130247-E942-4FE5-AA46-E30768A0C1B0` | UniKey Device Service | — | the only service |
| `00000989-0000-1000-8000-00805F9B34FB` | `UNIKEY_CHAR_COMMAND` | READ | lock **reads** the pending 4-byte command `[0,0,0,opcode]` |
| `00000979-0000-1000-8000-00805F9B34FB` | `UNIKEY_CHAR_DATA_STREAM` | READ+WRITE | bulk data: UUIDs, nonces, HMACs, firmware chunks |
| `00000999-0000-1000-8000-00805F9B34FB` | `UNIKEY_CHAR_STATUS` | WRITE | lock **writes** 4-byte flow-control/status; dispatch on byte[3] |
| `00000959-0000-1000-8000-00805F9B34FB` | `UNIKEY_CHAR_CERTIFICATE` | READ+WRITE | UniKey TLV "certificate" channel (enroll, settings, history, firmware, result codes) |

(A fifth characteristic `0x0969` is constructed in the app's static
initializer but never added to the service — dead code.)

### Session flow (touch-to-open / lock / unlock)

All steps driven by the lock:

1. Lock writes STATUS `[0,0,0,0x01]` — challenge-UUID begin.
2. Lock reads DATA_STREAM ← controller's 16-byte device UUID (BE).
3. Lock writes DATA_STREAM → its 16-byte lock UUID.
4. Lock writes STATUS `[1,x,x,0x01]` — complete; controller resolves the
   shared secret for that lock UUID.
5. Lock reads COMMAND ← pending `[0,0,0,opcode]`.
6. Lock writes STATUS `[x,x,lockState,0x02]` — nonce challenge start.
7. Lock writes DATA_STREAM → 32-byte nonce.
8. Lock writes STATUS `[…,0x03]` — HMAC request; controller computes
   `HMAC-SHA256(key = sharedSecret, msg = nonce XOR cmd)` (the 4-byte command
   XORed into nonce bytes 0..3) and leaves the 32-byte result in DATA_STREAM.
9. Lock reads DATA_STREAM ← 32-byte HMAC.
10. Lock writes STATUS `[result,battery,x,0x04]` — verdict: `0x01` accepted
    (byte[1] = battery level); `0xF0` denied **and the cached secret is wiped**
    (forces the key-present flow next time).

Other STATUS byte[3] types: `0x9A` firmware version, `0x9B` firmware-upgrade
marker, `0x12` bolt-position family, `0x15` enroll begin result, `0x30`
key-present begin.

### Command opcodes (last byte of the COMMAND value)

| Opcode | Meaning |
|--------|---------|
| `0x10` | Toggle lock/unlock (touch-to-open) |
| `0x12` | Bolt position / status query |
| `0x13` | Lock |
| `0x14` | Unlock |
| `0x15` | Tap-to-enroll (locks and the Kevo Plus gateway) |
| `0x19` | Lock history request |
| `0x9B` | Firmware upgrade begin — **advanced**: writes lock firmware; image format/signing not understood, a bad image can brick the lock, recovery path unknown |
| `0x00` / `0xFF` | Null command / dequeue sentinel |

Idle default pending set is `[0x10, 0x19]` (toggle + history upload). Battery
arrives in the `0x04` verdict STATUS; there is no separate battery opcode.

### Crypto

All pure Java (JCA + vendored Tink) — no native code:

- **Shared secret** (enroll): `HMAC-SHA256(key = X25519(phonePriv, lockPub
  from cert field 0x35), msg = lockNonce ‖ phoneNonce)`, both nonces 32 bytes.
- **Challenge-response**: `HMAC-SHA256(key = sharedSecret, msg = nonce XOR
  cmd)` as above.
- Certificates: UniKey TLV `[field:1][len:2 LE][value]`; int fields are LE.
  Recovered tags (from use sites — names were compile-time-stripped):
  `0x11` cert type (1 = device public cert, `0x22` = server-verified
  permission cert, `0x70` = DIQ/DIQR), `0x13` serialization version,
  `0x14`/`0xB9` creation unix time (u32 LE, both set at cert generation),
  `0x30` role (phone = 6), `0x32` device UUID, `0x35` X25519 pub, `0x36`
  Ed25519 pub, `0xB7` device settings (nested TLV map), `0x73` hardware type
  (u16; 19 = RPU gateway), `0x74` product descriptor (UTF-8, e.g. "RPU1").
  Post-auth certs are HMAC-signed (field `0x22` =
  `HMAC-SHA256(sharedSecret, serializedCert XOR nonce)`, computed with
  fields `0x22` **and** `0x21` removed — `0x21` is a server/CA signature
  field, also stripped from the firmware header cert before it is sent to
  the lock); nonces rotate every connection, so captured certs don't replay.
- Firmware blocks: CRC-16/BUYPASS (poly `0x8005`).

### Lock Information Certificate (LIC)

The result certificate the lock returns after DIQR commands; field layout
recovered from the app's lock-information certificate class:

| Tag | Meaning |
|-----|---------|
| `0x13` | serialization version (u8; server-timing-info path needs ≥ 3) |
| `0x17` | latest client nonce |
| `0x50` | device version, 3 bytes `[patch, minor, major]` → "major.minor.patch" |
| `0x60` | lock history cert (response to `0x19`); the same tag carries the server timing cert when written *to* the lock (command `0x18`) |
| `0xA5` | session certificate |
| `0xB4` | battery level (u8) |
| `0xB5` | lock status (u8): 0 unknown, 1 locked, 2 unlocked, 8 jammed, 9 jammed-locked, 10 jammed-unlocked |
| `0xBC` | state-change sequence number (u32 LE) — same counter as the advert trailer |
| `0xBD` | result code |
| `0xBE` | door position (2 B: position + change enum 0 none / 1 manual / 2 powered / 3 pending) |
| `0xC1` | battery charge status (gateway: 0 unknown / 1 charging / 2 not charging) |
| `0xC2` | main power status (gateway: 0 unknown / 1 available / 2 disconnected) |

**Time sync is cloud-mediated**: the app PUTs the base64 LIC to
`/Locks/{lockId}/Communications`; the 200 response field
`serverTimingInformationCertificate` is then relayed to the lock as DIQR
command `0x18` in cert field `0x60`. The server-side computation is not in
the app, so post-shutdown time sync (and thus scheduled-eKey fidelity) needs
that step reimplemented. Lock history paging: request DIQR field `0xBC` =
last-seen history sequence number (low 4 B LE); result code 2 (CONTINUE)
means more pages — re-issue `0x19`. The history record layout inside the
field-`0x60` cert was only ever parsed server-side (POST
`/Locks/{lockId}/History`).

Firmware payloads came from `GET /Locks/{lockId}/Firmwares` → JSON
`{certificate, image, version}` (base64 TLV header cert, opaque image blob,
version string). UPC transport: header nested in DIQR field `0x60` with
field `0x21` stripped, 900-byte image chunks in field `0x9C`, next offset
u32 LE in result field `0x9B`. The app never parses the image; its
format/signing is lock-side and no image has been obtained.

### There is no LAN protocol

A full-decompile sweep finds zero LAN code (`DatagramSocket`,
`MulticastSocket`, `NsdManager`, `WifiManager` — none used in `com.unikey.*`).
The Kevo Plus gateway is wired Ethernet + BLE only; every gateway command
transited the UniKey cloud (REST `https://resi-prd-api.unikey.com/api/…`,
WebSocket `wss://ws.unikey.com/…`). Gateway first-time setup is BLE — the phone
enrolls the RPU exactly like a lock. The gateway's vendor-documented "Local
Debug" ports (TCP 499/11000, plus 8100/8301/13252) appear nowhere in the app
and are the most interesting unexplored local surface.

## Security Notes

- The challenge-response itself is solid (rotating nonces, HMAC-signed certs,
  ECDH-derived secrets) — Kevo was one of only 4 locks *not* cryptographically
  broken in the DEF CON 24 smart-lock survey (2016).
- But there is **no link-layer encryption and no BLE pairing**: anyone in
  radio range can passively observe the application-layer ciphertext.
- NCC Group's 2022 advisory demonstrated a **relay attack against
  touch-to-open** (CVSS 6.8, all Kevo versions) — proximity is enforced
  behaviorally (dual antennas, accelerometer-based TTO disable), not
  cryptographically.
- A local controller gains TTO-level trust; treat its BLE credential store
  accordingly.
- What still needs an over-the-air capture (no link-layer encryption, so any
  LE sniffer works): lock-side nonce/fragmentation behaviour, firmware image
  blob format, and long-term acceptance of self-enrolled devices without
  cloud. Not recoverable from the app at all: the server-side computation
  behind time sync, and the history record layout (parsed only server-side).

## Tools Used

- [x] jadx 1.5.1 (decompile of `com.unikey.kevo` v3.1.1.33967p)
- [x] apkeep (APK acquisition, apk-pure mirror)
- [ ] BLE sniffer (Sniffle on TI CC1352/CC2652 recommended) — capture still needed

## References

- [NCC Group advisory: Kevo BLE proximity authentication relay attack (2022)](https://www.nccgroup.com/research/technical-advisory-kwiksetweiser-ble-proximity-authentication-in-kevo-smart-locks-vulnerable-to-relay-attacks/)
- [Kwikset support: Kevo app shutdown](https://www.kwikset.com/support/answers/what-does-the-kevo-app-shutdown-mean-to-my-kevo-door-lock) / [Weiser: Kevo app shutdown](https://ca.weiserlock.com/support/troubleshooting/support-articles/kevo-app-shutdown)
- [FCC ID NUL-MK1 (lock)](https://fccid.io/NUL-MK1), [FCC ID NUL-924 (gateway)](https://fcc.report/FCC-ID/nul924)
- DEF CON 24, "Picking Bluetooth Low Energy Locks" (Rose/Ramsey, 2016)
- UniKey patents: US9057210, US9218696, US9336637 (functional handshake only — no wire formats)
- Historical cloud-API clients: pykevoplus / aiokevoplus, kevo_ex (GitHub)
- Verification APK: `com.unikey.kevo` v3.1.1.33967p, md5
  `cbf31ab2a5beb9918d3e246c0855ad2a`, signer cert SHA1
  `04505561AF11DF80B14BE85B1E13B7593D2A95AB` (genuine UniKey cert)

## Contributors

- Liberated Bread RE workspace — APK re-verification and spec integration
