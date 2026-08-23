# BIO-key TouchLock BT

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: BIO-key International, Inc. (app/OEM: `com.champion.lock`, Play Store developer Keyssmart)
> **Manufacturer Status**: Abandoned (company alive; TouchLock consumer hardware line discontinued, product pages gone)

## Overview

The TouchLock BT family is a line of Bluetooth Low Energy keyless locks —
padlocks (XS/XL), a TSA luggage lock, a bike lock and a U-lock — sold by
BIO-key from about 2017 and now discontinued. Everything about them was
recovered by decompiling the official Android app (TouchLock BT v2.2.1,
`com.champion.lock`, jadx output; sha256 in the spec's `sources`).

Two facts make this family unusually rescue-friendly:

- **There is no cloud at all.** No HTTP client, endpoint, account, sync or
  OTA mechanism exists anywhere in the app. The lock cannot die from a
  server shutdown; the only vendor risk is the app vanishing from Google
  Play, and the protocol below replaces it entirely.
- **There is no real cryptography.** The rolling credential is literally the
  current timestamp split into bytes. A local client can generate valid
  commands with no secrets beyond a one-time enrollment.

No Home Assistant/ESPHome integration or public reverse-engineering repo for
this family was found — this spec is the starting point.

## Hardware

| Property | Value |
|----------|-------|
| Model Numbers | BL0509 (TouchLock BT XS), BL1209 (TouchLock BT XL), BS1609 (TouchLock TSA BT); bike lock and U-lock variants; OEM rebadges (e.g. `Joi_Lock`) |
| Chipset | Unknown (not identifiable from the app) |
| Radio | BLE 4.x (single-mode, 2402–2480 MHz) |
| FCC ID | 2AIKJ-BL (grantee BIO-KEY; padlock models) |

Non-BLE TouchLock variants (fingerprint sensor on the lock, no Bluetooth)
exist and are **not** covered here.

## Initial Setup

There is no network to join — "setup" is BLE enrollment, required before the
lock will open. Facts below are read from the decompiled app, re-checked
against the jadx output, and not yet replayed against hardware.

| Property | Value |
|----------|-------|
| Setup required | Yes (admin enrollment, BLE only) |
| Method | `ble_provisioning` |
| Advertised names | `TSA_BT`, `TSA_PLUS`, `XL_BT`, `XL_PLUS`, `Ble_Lock`, `Bike_BT`, `Bike_Pr`, `Joi_Lock`, `U_Lock`, `ULockPr` (fallback: any name containing `LOCK`) |
| Passphrase protection | not_applicable (no WiFi; BLE bonding is Just Works) |
| Confidence | medium (decompile-derived, not hardware-run) |

Enrollment flow:

1. Scan unfiltered; match the name patterns above plus the presence of a
   manufacturer-data status byte.
2. Connect, bond (no PIN), discover services, enable notifications on
   `67ac8801-…`, wait ~1.2 s.
3. If the status byte's registered bit (bit 4) is clear, send
   **RegisterAdmin (0x80)** with a fresh client-generated 8-byte admin ID
   and the current time-based password.
4. Store the admin ID and password locally — they are the only credentials.

**Factory reset**: a BLE command, not a button. **FactoryInit (0x8f)**
carries the admin ID plus the 8-character factory password (one hex-digit
character per byte; the app's own dialog hints the default is `00000000`).
It clears the admin, all enrolled users, and returns the lock to the
unregistered state. No physical reset procedure is documented in the app.
This has not been executed against hardware — on a lock, treat reset flows
with care.

**Rebinding to a new phone/controller**: in place, no reset needed. The new
client gets the admin's current password out-of-band (the official app
sends it by SMS — there is no server), sends **UserRegistrationRequest
(0x90)** with that password and its bytewise complement, then
**UserRegistration (0x91)** to install its own credentials. A reset is only
needed when every credential is lost.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `67ac8800-a0eb-11e6-80f5-76304dec7eb7` | TouchLock lock service | The only application service |
| `67ac8801-a0eb-11e6-80f5-76304dec7eb7` | Response/status (notify) | Responses + unsolicited status (opcode `ff`) |
| `67ac8802-a0eb-11e6-80f5-76304dec7eb7` | Command write (write-no-response) | All commands, 20-byte frames |

### Commands

Every command is exactly 20 bytes, written to `67ac8802-…`:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Opcode |
| 1 | 1 | 0x00 |
| 2–9 | 8 | Payload A |
| 10–17 | 8 | Payload B |
| 18 | 1 | 0x00 |
| 19 | 1 | Checksum = `(0x5A − sum(bytes[0..18])) & 0xFF` |

**Response** (notify, parsed as a hex string):

| Chars | Description |
|-------|-------------|
| 0–1 | Echoed opcode |
| 2–3 | Error code: `00` ok, `01` invalid command, `02` checksum, `03` wrong password, `04` invalid user ID, `05` already registered, `06` user record full, `07` unbonded device |
| 4–5 | Status byte |

Status byte: bit 7 = lock state (polarity unconfirmed), bit 4 = registered
flag, bits 2–0 = battery 0–7. The same byte is broadcast in manufacturer
advertisement data while disconnected — state and battery can be tracked
passively.

Opcode table: `00` OpenLock · `01` TimeStamp (RTC sync, must precede
unlock) · `80` RegisterAdmin · `81` RemoveUser · `82` GetUserInfo (unused) ·
`8c`/`8d` change factory password · `8f` FactoryInit · `90`/`91` user
registration · `ad` GetMac (unused) · `cc` FindLock (fixed payload
`22 44 66 88 88 66 44 22` / `11 33 55 77 77 55 33 11`) · `ff` UpdateStatus
(unsolicited, device→client).

The "rolling password" is the current timestamp `yy-MM-dd-HH-mm-ss-SSSS`
split into eight two-digit decimal groups, each written as one hex-parsed
byte. Unlock = send TimeStamp, then OpenLock with the stored password in
payload A and the new time-based password in payload B; on success the new
password becomes the stored one.

## Cloud Dependency & Home Assistant Guidance

**None.** No cloud exists, nothing needs a keep-alive, and nothing breaks
when the vendor disappears. The app itself is archived (see the spec's
`sources`) in case the Play Store listing goes away.

For Home Assistant:

- There is no ready-made integration. Everything needed to write one is in
  the spec: static 128-bit UUIDs, the 20-byte frame format, the additive
  0x5A-seeded checksum, and the time-derived password generator.
- The lock is BLE-only, so use an ESPHome `bluetooth_proxy` (or any BLE
  adapter) within radio range; "remote access" just means a bridged local
  connection.
- Track state and battery passively from the advertisement status byte —
  no connection needed. The manufacturer-data company ID is still unknown
  (needs one capture), so identify adverts by name pattern until then.
- Expect bonding (Just Works, no PIN); the lock appears to reject unbonded
  writers with error `07`. The official app deliberately unpairs on
  disconnect — an integration that keeps a persistent bond is in
  uncharted-but-plausible territory.
- Honor the app's pacing: ~1.2 s pause after enabling notifications, and
  always sync the RTC (TimeStamp) before OpenLock.

## Tools Used

- [ ] Wireshark / nRF Connect — no capture exists yet
- [x] jadx decompile of `com.champion.lock` v2.2.1

## References

- [TouchLock BT on Google Play](https://play.google.com/store/apps/details?id=com.champion.lock)
- [APKCombo version history](https://apkcombo.com/touchlock-b/com.champion.lock/)
- [FCC ID 2AIKJ-BL](https://fcc.report/FCC-ID/2AIKJBL)
- [FCC manual mirror (model list)](https://fccid.io/m/a149d2e83326ce6fab053504a390ff868f705671805d3463519992b539bceadb.pdf)
- Machine-readable spec: `device-specs/devices/biokey-touchlock-fingerprint-lock.yaml`

## Contributors

- Automated research agent — APK acquisition, decompile, initial RE dossier (2026-08)
