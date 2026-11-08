# Piaggio Fast Forward gita / gitamini — Research Notes

Updated 2026-11-07 from mygita Android/iOS 1.7.4, public manuals and static
protocol analysis. No robot, app session, BLE write, reset, SSH connection,
firmware update or network scan was used. All protocol statements are static
findings, not a successful hardware session.

## Product and safety

PFF's robots visually follow their owner using stereo depth/RGB cameras and,
on Mini, radar. The physical Pair/Park button initiates visual pairing and
following. The app does **not** expose a normal remote-drive, velocity,
steering or start-following command. Do not treat `activate robot` as such a
command. This is a self-propelled robot: begin with read-only evidence and
keep people clear during any owner-approved test.

Advertisement model IDs: 1 original gita, **2 gitamini**, 3 internal pro enum,
4 gitaplus, 5 tag, **11 licensed Disney Mini**. G1T4-M1N1 and Grogu are
separate Disney submodels. Unknown IDs need a new profile rather than falling
back to original-gita behavior. Mini documentation supports 2.4/5 GHz Wi-Fi;
only original gita has the app's 5 GHz blacklist. Mini does not support the
generic manual's Bluetooth-audio streaming section, according to PFF app help.

## Discovery and advertisements

The scanner filters on 16-bit service UUID `0x9999` and manufacturer company
**0x083B** (wire bytes `3b 08`). The inner manufacturer payload uses TLV tags:
A1 serial, A2 cloud object ID, A3 color, A4 status, A5 battery, A6 model, A7
message code, A8 connected-user ID, A9 checksum and AA odometry. Minimum
payload length is 25 bytes. Primary states include ready/following/parked/
charging/upgrading/shutdown and OTA failures; secondary state reports latch;
flags report mute/stealth/open-access/smarts.

The A9 interpretation takes a suffix length and expects a byte-wise negative
sum, but a valid capture is still needed before generating advertisements.
Serials, cloud/user IDs, odometry and state are visible to nearby receivers;
redact them in research captures.

## GATT service

All characteristics share `87654321-1234-5678-1234-56789abcdef0`:

| Suffix | Role |
|---|---|
| `…def1` | Authenticated session-key command write |
| `…def2` | Operational encrypted command write |
| `…def3` | Plaintext Wi-Fi notifications |
| `…def4` | Per-phone identity write |
| `…def5` | Phone ECDH public-key write |
| `…def6` | Robot ECDH public-key read |
| `…def7` | General plaintext notifications |
| `…def8` | Version/build string read |
| `…def9` | Registration/session feedback notifications |
| `…defa` | Registration command write |
| `…defb` | Session-key exchange write |

The app requests MTU 185 and uses 181 ciphertext bytes plus one continuation
marker per write. General operation timeout is 30 seconds; session feedback
has an 8-second wait. Registration/session feedback has its own encrypted and
fragmented handling; do not apply the normal plaintext-notification parser to
it.

## Two credential layers

### Per-connection ECDH

1. Read the robot public key on `…def6`.
2. Generate a phone secp256k1 key pair and write it to `…def5`.
3. SHA-256 the ECDH secret, represent it as 64 hex characters and split that
   string in half. Hex-decoding each 32-character half yields a 16-byte AES key
   and a 16-byte IV.
4. Operational plaintext is `[command][0x7f][data…]`, padded to 10 bytes when
   empty. Encrypt with AES-128-CBC/PKCS#7 and send raw ciphertext, not Base64.

This key encrypts ordinary commands. ECDH alone does not authenticate the
robot. No AEAD tag was found in the reviewed command builder.

**Runtime caveat:** the JavaScript requests one native AES module name while
the recovered Android package registers another. This could be a compatibility
defect or an unresolved bridge detail. Confirm the normal app connection
before implementing the algorithm; static analysis does not prove it works.

### Cloud-issued session credential

A fresh session-key request sends robot values to `/session-keys` with the
owner's bearer token. The returned 64-hex-character credential is split into
another AES key/IV pair and used to authenticate to the robot. The app stores
it by robot UUID and chooses existing-key verification when offline or when
it is no more than seven days old; older keys are refreshed when online.

This is a credible **post-registration offline-control candidate**, not proof
of unlimited offline use or offline enrollment. Revocation, reset, logout,
reinstall and time/policy behavior need hardware tests. Never publish session
keys, nonces, ECDH secrets, bearer tokens or verification payloads.

## Command and notification map

- 7–9: nonce/new/existing authentication;
- 50–59: AP list, join/disconnect/forget/connect Wi-Fi, IP and profiles;
- 60–68: registration, session key, alternate auth and registration name;
- 69–77: speaker, mute, stealth, open access, name and audio discovery;
- 78–79: latch lock/unlock;
- 80–87: install, version, speaker re-pair, volume, download, uptime, logs;
- 88–93: Wi-Fi toggle, remove device, OTA status, smarts;
- 99–102: disconnect, activate, disable/enable SSH.

Wi-Fi join data is `<SSID> password <password>` inside the encrypted command.
Notifications cover IP, latch, settings, Wi-Fi, version, OTA, primary status,
session-key state, volume, uptime, logs, pair lock and SSH result. Fragment
marker ranges and the operational 0/1 continuation convention are separate;
do not merge them without a capture.

SSH enable first calls an authenticated support endpoint and then encrypted
command 102. It is support-gated, not an offline developer-mode password or
proof that SSH is exposed.

## Registration and OTA

Enrollment requires a **10-character Code 128 serial** and a **20-character QR
secret beginning `pff`**, followed by authenticated cloud and robot
verification. The printed QR is single-use. The app performs ECDH, obtains a
robot creation payload, exchanges it with `/gitas`, verifies the response with
the robot, then posts QR/verification data to `/registrations`. Serial or
advertisement possession alone is not an enrollment path. Never publish the
QR secret or verification values.

Mini and every other non-original model select OTA V2. The phone reads build
capabilities, requests authenticated `/ota-v2-check` and `/ota-v2-infos/{id}`,
then tells the robot to download (85) or install (80). The phone path does not
download the image; the robot's Wi-Fi is the place to capture retrieval. V2
models a staged/rollback-capable flow but does not prove an A/B partition on
every component. No public firmware image or device packet capture was found.

## App and evidence

Analyzed Android 1.7.4 (versionCode 5254323; separate JS/internal version IDs
1070004 and 12), iOS 1.7.4. Public API `/info/version` reported API 1.16.21
and minimum app 1.4.5; this is policy metadata, not robot firmware. The
original 1.7.2 research is superseded by this pass.

Hardware identifiers remain cautious: RealSense is a lead, not proof of a
specific Mini camera; Jetson TX2 is documented for original gita, not Mini.
Radar filing 2AY6H-101187 is a candidate, not a confirmed module mapping.
Public release notes through Mini 2.5.1 are not proof of the latest firmware.

## Next evidence

1. Sanitized passive advertisements in several Mini states, checking model,
   state, odometry units and checksum.
2. A normal owner app connection resolving the native crypto-name caveat.
3. Preserved-session offline reads after registration, phone restart and the
   seven-day boundary, followed by reset/revocation tests.
4. An owner-approved OTA capture identifying the robot download URL and image
   format without installing research firmware.
5. Module/regulatory labels instead of assigning compute, camera, radar or
   Wi-Fi parts from circumstantial evidence.
