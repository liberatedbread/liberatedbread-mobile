# Piaggio Fast Forward gitamini / gita pro

> **Status**: Spec available (untested; static app analysis)
> **Protocol**: BLE with application-layer ECDH and AES-CBC
> **Manufacturer**: Piaggio Fast Forward, Inc. (active)

## Overview

gitamini is a self-propelled cargo robot that visually follows its owner using stereo
depth/RGB cameras and radar. Following starts with the robot's physical Pair/Park
button, not with a phone/GPS/Bluetooth-tracking API.

The mygita app exposes registration, Wi-Fi, settings, latch, logs and OTA. No ordinary
remote-drive, velocity, steering or start-following command was found. `activate robot`
is not evidence of such a command and is deliberately not offered as one.

**Pro boundary:** advertisement model 3 is named `gita pro` in the app, but no retail-Pro
manual, packet capture or distinct protocol profile was found. Pro is a reported variant
of this BLE family, not a separately verified product. Model 2 is gitamini. Unknown model
IDs need a new profile rather than the app's original-gita fallback.

## Safety

!!! danger "Self-propelled robot"
    Start with passive advertisements and read-only GATT operations. Do not send
    `activate robot`, latch, network, SSH or firmware commands as discovery probes.
    Keep people, pets and obstacles clear during any owner-approved test, and never test
    motor behavior with an unregistered write.

## Discovery and advertisements

The app normally scans for service `00009999-0000-1000-8000-00805f9b34fb` and
manufacturer company `0x083B` (wire bytes `3b 08`). There is no useful name prefix.

The manufacturer payload contains TLV records: serial, cloud object ID, color, three
status bytes, battery, model, message code, connected user, checksum and odometry.
Minimum length is 25 bytes. Model 2 is Mini; model 3 is the reported Pro. Battery is a
percentage, with 255 meaning unknown. Primary states include ready, following, parked,
charging and OTA states; secondary state reports latch; flags report mute, stealth,
open access and smarts.

The checksum selector and negative byte-sum rule are recovered, but the exact suffix
layout still needs a valid capture before generating or validating advertisements.
Serials, cloud/user IDs and odometry are visible to nearby receivers and must be
redacted from research captures.

## Initial setup and registration

| Property | Value |
|----------|-------|
| First enrollment | Vendor account, serial barcode and single-use QR secret |
| Existing registration | Offline session-credential reuse is a candidate, not verified |
| BLE pairing | OS-level bond plus application-layer ECDH/session authentication |
| Wi-Fi provisioning | Encrypted BLE command; Mini supports 2.4/5 GHz |
| Reset | Unknown |

### Existing registration (offline candidate)

1. Scan for service 0x9999 and company 0x083B, then select the correct model.
2. Create the OS-level BLE bond. The physical Pair/Park button is for visual following,
   not BLE pairing.
3. Read the robot ECDH public key on `...def6`, generate a secp256k1 phone key pair and
   write its public key on `...def5`.
4. Subscribe to Wi-Fi (`...def3`), general (`...def7`) and registration/session
   (`...def9`) notifications before any authentication or session-key write.
5. Request verification of the stored session credential with command 63 on `...defb`;
   decrypt its type-109 response to recover `n2` as detailed below.
6. Authenticate with command 9 on `...def1` using `n2`, encrypted with the stored
   credential. The app selects existing-key verification when offline or within seven
   days; with connectivity and an older key it requests a fresh one. Start with read-only
   version, IP or OTA-status requests.

This path does not prove unlimited offline use. Revocation, reset, logout/reinstall and
long-term policy need hardware tests.

### First enrollment (cloud required)

1. Create or sign in to a mygita account and scan the 10-character Code 128 serial and
   20-character QR secret beginning `pff`.
2. Match the serial to the robot and perform ECDH.
3. Subscribe to registration/session feedback on `...def9` before command 60 or any
   session-key write, so replies are captured during the eight-second feedback wait.
4. Request robot creation data with command 60 and exchange it with authenticated
   `/gitas`, then verify the response with command 61.
5. Post the QR payload and robot verification message to authenticated `/registrations`.
6. Set the returned identity, send command 68 and configure Wi-Fi/notifications.

Possession of the serial or advertisement alone is not enrollment. The printed QR is
single-use. Never publish the QR secret, bearer token, verification payloads, session
keys, ECDH secrets or owner identifiers.

## GATT service

All characteristics share `87654321-1234-5678-1234-56789abcdef0`. The app requests MTU
185 and uses write-without-response. Properties are app-derived; no live GATT dump
exists.

| Suffix | Role |
|--------|------|
| `...def1` | Authenticated session command write |
| `...def2` | Operational encrypted command write |
| `...def3` | Plaintext Wi-Fi notifications |
| `...def4` | Per-phone identity write |
| `...def5` | Phone ECDH public-key write |
| `...def6` | Robot ECDH public-key read |
| `...def7` | General plaintext notifications |
| `...def8` | Version/build string read |
| `...def9` | Registration/session feedback notifications |
| `...defa` | Registration command write |
| `...defb` | Session-key exchange write |

General operation timeout is 30 seconds; session feedback has an 8-second wait.
Registration/session feedback uses a different encrypted and fragmented parser from
normal plaintext notifications, with `$$$$$` and `#####` delimiters and a random
10-character phone identity prefix where applicable.

## Encryption and command framing

Two different credential layers must not be confused:

1. **Per-connection ECDH:** derive a SHA-256 digest as specified below, render its 64
   hexadecimal characters and split them in half. Hex-decoding each 32-character half
   gives a 16-byte AES key and 16-byte IV. Ordinary operational commands use this pair.
2. **Cloud-issued session credential:** a 64-hex credential is also split into an AES
   key and IV and used to authenticate the robot session. It is stored by robot UUID.
   Fresh issuance needs the cloud; existing verification can work offline.

Write the phone public key to `...def5` as a **raw 65-byte uncompressed SEC 1 point**:
`0x04 || X || Y`, with both coordinates unsigned, big-endian and 32 bytes wide. The
app's internal 130-character hex representation is hex-decoded before the write; do not
send ASCII hex. On `...def6`, accept either that form or a raw 33-byte compressed SEC 1
point (`0x02`/`0x03 || X`) and validate the point. The parser supports both, but no
capture establishes which form every firmware emits.

The ECDH secret is the shared point's X coordinate converted to **lowercase hexadecimal
without leading-zero padding**. SHA-256 the ASCII bytes of that hex text—not the raw or
hex-decoded coordinate. Its length is normally 64 characters but can be shorter. The
synthetic vector in `protocol_details.ecdh.test_vector` exercises a 63-character input,
including both public keys and the resulting AES key/IV.

No-data plaintext is ten bytes: `[opcode][0x7f][00 × 8]`. Data-bearing plaintext is
`[opcode][0x7f][data…]`. Encrypt the whole buffer with AES-128-CBC/PKCS#7 and send raw
ciphertext, not Base64 text. Split ciphertext into 181-byte pieces and append `0` for
more chunks or `1` for the final chunk.

## Saved-session authentication

Each nonce is 16 random bytes rendered as **32 lowercase hexadecimal ASCII
characters**. `n1` is generated by the phone; `n2` comes from the robot/cloud.
The account `user_id` is not the robot UUID.

1. With `...def9` already subscribed, write command 63 to `...defb` with plaintext
   `[0x3f][0x7f][user_id_utf8][n1_ascii]`, encrypted using the **per-connection
   ECDH key/IV**.
2. Within eight seconds, accept a type-109 response. Reassemble the registration
   feedback, strip its identity prefix and `#####` terminator, and decrypt the outer
   command using ECDH. The first plaintext byte is `0x6d` (109). Decode the inner
   Base64 ciphertext and decrypt it using the **saved session credential**. Its
   plaintext is `n1_ascii.n2_ascii`; require `n1` to match exactly. Type 110 means
   expired and type 111 means invalid; stop on either or on timeout.
3. Write command 9 to `...def1` with plaintext `[0x09][0x7f][n2_ascii]`, encrypted
   using the **saved session credential**. Send only `n2`, not the credential or
   `n1`. A newly issued credential uses command 8 with the same layout.
4. The reviewed app parses no dedicated success response to command 9. Require a
   subsequent version read on `...def8` or another read-only response before
   calling the offline session established. Type 109 answers command 63, not
   command 9.

For fresh issuance, command 62 uses the same outer request as 63 with opcode
`0x3e`. Its successful type-62 payload is `key_part.n2_ascii.payload`; post
`key_part`, `payload` and `n1` to authenticated `/session-keys`, then use the
returned credential and `n2` with command 8. No authenticated request was made
during research.

Normal notifications are a type byte followed by UTF-8/ASCII with trailing newlines
trimmed. The separate notification fragment markers 251–255 must not be merged with the
operational 0/1 continuation convention without a capture.

The reviewed Android package requests one native AES module name and registers another.
This may be a compatibility defect or an unresolved bridge detail. The algorithm is
recovered, but a normal app connection must confirm it before a third-party client is
expected to work.

## Known command surface

Only commands with a documented no-data or payload shape are executable entries in the
YAML. Other opcodes remain documentation, not instructions to send ten zero-padded
bytes.

| Operation | Opcode / payload |
|-----------|------------------|
| AP list | 50 |
| Join Wi-Fi | 51 + ASCII `<SSID> password <password>` |
| Disconnect / forget Wi-Fi | 52 / 54 |
| Get IP / current connection / profiles | 53 / 55 / 56 |
| Connect remembered network | 57 |
| Mute / stealth / open access | 72 / 73 / 74 |
| Latch lock / unlock | 78 / 79 |
| Install / download OTA | 80 / 85 |
| Get version / uptime | 81 / 86 |
| Toggle Wi-Fi / remove device | 88 / 89 |
| OTA status / start / stop notifications | 90 / 91 / 92 |
| Toggle smarts | 93 |
| Disconnect client | 99 |
| Enable SSH, support-gated | 102 |

Authentication uses 7–9 and 62/63. Registration uses 60–68. Wi-Fi, latch, open-access,
SSH and update commands are advanced operations, not scan probes. No motor-control
entity is declared.

## OTA V2

Mini, reported Pro and every other non-original model select OTA V2:

1. Read version/build capabilities on `...def8`.
2. With the owner's bearer token, request `/ota-v2-check?gitaId=<id>&buildId=<build>`.
3. If an update ID is returned, request `/ota-v2-infos/{id}` for notes, build,
   minimum app version, upload date and total bytes.
4. Send 85 to download or 80 to install. Notification 122 reports status/percent.

The robot retrieves the image over its own Wi-Fi; the reviewed phone path does not
download it. No public firmware image or update URL was obtained. Staged and rollback
states do not prove A/B partitioning on every component. OTA and SSH commands require
deliberate authorization and a recovery path.

## Remaining unknowns

- Valid advertisement/GATT captures, checksum suffix, state values and odometry units.
- Native crypto-module runtime behavior and per-op payload/response layouts.
- Offline reuse across phone restart and the seven-day boundary, plus revocation/reset.
- OTA image URL, format, signature and rollback behavior.
- Any retail-Pro-specific profile or capability differences.
- Exact compute/camera/radar modules; RealSense and radar filing `2AY6H-101187` are
  leads, not confirmed Mini mappings. Jetson TX2 is documented for original gita.
- Robot-side bond/registration removal, SSH credentials and the meaning of `activate
  robot` (100).

## References

- [Mini/Plus user manual](https://knowledge.mygita.com/hubfs/mini_plus_UserManual.pdf?hsLang=en)
- [Mini quick start](https://knowledge.mygita.com/hubfs/Quickstart-gita-mini.pdf?hsLang=en)
- [Mini setup and registration](https://knowledge.mygita.com/setting-up-getting-started)
- [General mygita app use](https://knowledge.mygita.com/general-use-of-the-mygita-app)
- [Mini sensor overview](https://piaggiofastforward.com/blog/all-about-gitaminis-sensors)
- [Mini release notes](https://knowledge.mygita.com/release-notes)
- [mygita on Google Play](https://play.google.com/store/apps/details?id=com.piaggiofastforward.mobile)
- [PFF open-source notice](https://piaggiofastforward.com/opensource)
