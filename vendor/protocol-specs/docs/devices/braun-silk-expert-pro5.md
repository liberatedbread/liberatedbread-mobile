# Braun Silk-expert Pro 5 (PL5xxx)

> **Status**: In Progress (protocol fully mapped from the decompiled Braun IPL app; not yet replayed against hardware by this project)
> **Protocol**: BLE (custom GATT command channel on P&G's shared grooming-SDK UUID scheme); some SKUs also have Wi-Fi, provisioned over BLE
> **Manufacturer**: Braun (Procter & Gamble)
> **Manufacturer Status**: Active — and it barely matters: the device works fully standalone

## Safety

!!! danger "IPL can permanently damage skin and eyes"
    This is an intense-pulsed-light hair-removal handset (a SensoAdapt skin-tone sensor that gates each flash). Improper use
    can cause permanent skin burns, blistering, discoloration or scarring, and
    serious eye injury. Patch-test first, match the intensity to your skin tone
    (IPL is unsafe on the darkest skin tones), never treat broken, tanned,
    tattooed or moled skin, and keep it away from the eyes. This project ships an
    **experimental, unaffiliated** third-party client — the manufacturer's own
    instructions govern.

- Manufacturer safety guidance: <https://us.braun.com/en-us/female-grooming-tips/hair-removal/ipl-safety>
- Archived copy (web.archive.org), if the page above is offline: <https://web.archive.org/web/20260515164732/https://us.braun.com/en-us/female-grooming-tips/hair-removal/ipl-safety>

## Overview

The Braun Silk-expert Pro 5 (PL5xxx family, Type 6031) is a mains-powered IPL
(intense pulsed light) hair-removal device. It is one of the easiest devices
in this knowledge base to keep alive: **the hardware does everything that
matters on its own.** Flashing is gated by the device's own skin-tone sensors
(per the vendor manual it only activates with both sensors against the skin),
and the companion app — *Braun IPL* (`com.pg.grooming.braun.ipl`) — never
fires a flash, never gates intensity, and has **no activation or unlock
step** anywhere in its BLE layer.

What the app does over BLE is bookkeeping: session start/pause/resume/finish
markers, read-back of session results (skin tone, mounted head, energy level,
flash count), triggering a skin-tone measurement or patch test, an OTA hook,
and — on Wi-Fi SKUs — provisioning the device onto a network so it can phone
home via AWS IoT MQTT. The only cloud-gated step in the whole picture is the
vendor's issuance of per-device AWS certificates during provisioning, and even
that is optional: provision your own MQTT endpoint instead, or never provision
at all.

The protocol was recovered by static analysis of Braun IPL v3.3.3
(versionCode 7067; base APK sha256
`0ad7cfaa1249b64420de941d5467bd260111f365f4fdc86bd2cb4c80bd842b0c`). Nothing
has been replayed against hardware yet — the open questions below are the
verification list.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Silk-expert Pro 5, PL5xxx family (e.g. PL5124, PL5347), Type 6031 |
| Chipset | Unknown — firmware is built on P&G's shared "grooming" BLE SDK (the same one as the Oral-B iO line) |
| Radio | BLE; some SKUs add Wi-Fi (provisioned over BLE, then AWS IoT MQTT). Which PL5xxx SKUs have Wi-Fi is an open question |
| FCC ID | Not recorded — needs a label photo |

Mains-powered; 400,000-flash rated lifetime enforced by the hardware.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No — the device flashes standalone out of the box |
| Method | `ble_direct` (primary) / `ble_provisioning` (optional, Wi-Fi SKUs only) |
| Setup AP / advertised name | None; identified by manufacturer-data company ID `0x00DC` + device-type byte `0x61` |
| Passphrase protection | plaintext payloads on the (bonded, encrypted) BLE link — only if you provision Wi-Fi at all |
| Confidence | medium (read from the decompiled app; not replayed here) |

The standalone flow:

1. Scan for a manufacturer-data AD structure (`0xFF`) with company ID
   `0x00DC` (wire bytes `DC 00`, little-endian) whose second payload byte —
   the device type — is `0x61` (the Silk-expert Pro 5 generation). The vendor
   app uses no name or service-UUID filter at all.
2. Connect with `autoConnect=false`, negotiate **MTU 515**.
3. Bond (see Pairing below).
4. Subscribe to Status (`3C03`) and Push (`3C04`) notifications and Read
   (`3C01`) indications.
5. Sanity-check the channel with GET DEVICE_DATA (`C0 03`) and GET
   SESSION_DATA (`C0 04`).

The optional Wi-Fi provisioning flow sends EXECUTE ENTER_PROVISIONING
(`C3 06`), then SETs a separate provisioning opcode namespace
(WIFI_SSID=2, WIFI_PSWD=3, TEST_WIFI=4, HOST_PORT=5, AWS_KEY=6, AWS_CERT=7,
AWS_ROOT_CA=8, END_CONFIG=9, WIFI_AP_LIST=10, DEVICE_UUID=11, TIMEZONE=13,
THING_NAME=14) as UTF-8 payloads. The vendor flow fetches per-device AWS
certificates from its GraphQL API (account required); a replacement client
can write its own MQTT endpoint and certificates instead and skip the vendor
cloud entirely.

**Factory reset**: there is no physical procedure known. Reset is a BLE
command — EXECUTE DEVICE_RESET (`C3 31`, cmdId 49). What exactly it clears is
unverified; the device-state enum includes `FACTORY`, so it presumably
returns the unit to factory state (bond and any Wi-Fi/AWS credentials gone).
Marked `verified: false` in the spec — nobody here has sent it.

**Rebinding**: BLE-only use has nothing to rebind — a new phone just bonds
(forget a stale bond in the old phone's OS Bluetooth settings if the device
refuses). A Wi-Fi-provisioned unit moves networks by re-running provisioning
over BLE; the old network does not need to be up.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Unknown — the app always bonds; whether the device *refuses* an unbonded client is unverified |
| Security mode | Unknown — no passkey/PIN appears anywhere in the app, so nothing user-visible |
| Bonding | `required` — the app bonds explicitly and the device has a BONDING operation state |
| PIN source | none seen |
| One central at a time | Unknown |
| One bond at a time | Unknown |
| Confidence | low (inferred; needs an HCI snoop or an unbonded connection attempt) |

No pairing-mode button press exists — the device advertises whenever powered.
No BLE command carries a credential: the bond is the entire access-control
story, so treat bonded access as read access to session data and skin-tone
measurements.

## Protocol Summary

### BLE Services

All characteristics are 128-bit UUIDs on the template
`A0F0XXXX-5047-4D53-8208-4F72616C2D42` (the trailing bytes are ASCII for the
Oral-B brand name — P&G's shared grooming SDK; the same scheme and the same
`3Cxx` command-channel roles appear in the `oral-b-io-smartbrush` spec).
**The containing service UUID was not recovered** — locate characteristics by
enumeration, not by service.

| UUID suffix | Name | Access | Description |
|-------------|------|--------|-------------|
| `3C00` | Command | write | All command verbs: `{opcode, cmdId}` |
| `3C01` | Read | read + indicate | GET responses and live state |
| `3C02` | Write | write | SET payloads (UTF-8: SSID, password, certificates) |
| `3C03` | Status | notify | Command acks, 3 bytes `{opcode, cmdId, status}` — status 0=OK, 1=BUSY, 2=ERROR |
| `3C04` | Push | notify | Unsolicited events (see reason codes below) |
| `4C00` | Raw | notify | FlatBuffers raw sensor stream (IMU, skin/contact, temperature, shot count) |

### The three verbs

Written to `3C00`; no framing, checksum or credential beyond the opcode:

- **GET** — write `{0xC0, cmdId}`, read the response from `3C01`.
- **SET** — write `{0xC1, cmdId}`, write payload bytes to `3C02`, commit with
  `{0xC2, cmdId}`.
- **EXECUTE** — write `{0xC3, cmdId}`, await the Status notification
  `{0xC3, cmdId, status}`.

### Operational opcodes

| cmdId | Name | Verb | Notes |
|-------|------|------|-------|
| 2 | DEVICE_VERSION | GET | hex string |
| 3 | DEVICE_DATA | GET | byte 2 device state, byte 3 Wi-Fi state, byte 6 raw-stream flag |
| 4 | SESSION_DATA | GET | 23-byte layout below |
| 5 | MEASURE_SKIN_TONE | EXECUTE | trigger the skin-tone sensors |
| 6 | ENTER_PROVISIONING | EXECUTE | switches to the provisioning namespace |
| 7–10 | SESSION_START / FINISH / PAUSE / RESUME | EXECUTE | bookkeeping markers |
| 11 | START_PATCH_TEST | EXECUTE | the manual's pre-treatment skin test |
| 12 | OTA_UPDATE_START | EXECUTE | advanced: transfer format undocumented |
| 49 | DEVICE_RESET | EXECUTE | advanced: presumably returns to factory state |
| 50 | PROTOCOL_NAME | GET | UTF-8 |
| 51 | READ_RAW | EXECUTE | enable the `4C00` stream |

### SESSION_DATA response (GET 4, read from `3C01`) — 23 bytes

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Operation state: 3=IDLE, 4=BONDING, 5=PROVISIONING, 6=SKIN_TONE_MEASUREMENT, 7=SESSION_RUNNING, 9=PATCH_TEST, 10=OTA, 255=NOT_SET |
| 1–16 | 16 | Session UUID (two big-endian 64-bit halves) |
| 17 | 1 | Mounted head: 0=none, 1–31 standard, 33–63 precision, 65–95 large, 97–103 mini-precision, 129–135 smart-flex |
| 18 | 1 | Energy level: 0=NORMAL, 1=SENSITIVE, 2=EXTRA_SENSITIVE, 255=NOT_SET |
| 19–20 | 2 | Skin tone, big-endian u16 (raw; the app buckets it into 10 tones — table not extracted) |
| 21–22 | 2 | Flashes fired this session, big-endian u16 |

DEVICE_DATA (GET 3): byte 2 = device state (0=FACTORY, 1=BONDED, 2=NORMAL,
3=OTA_READY, 254=UNRECOVERABLE_ERROR), byte 3 = Wi-Fi state, byte 6 =
raw-stream-enabled. Full length and remaining bytes unestablished.

### Push events (`3C04`)

Byte 1 = the command value the event relates to, bytes 2–3 = big-endian u16
reason. Reasons: `0x0001`/`0x0002` command end success/fail, `0x0003` buffer
data updated, `0x1001`/`0x1002` standby/sleep, `0x1003`/`0x1004` **session
started/ended by the device itself** (the important pair — flashing is always
device-driven), `0x1005`–`0x1007` OTA lifecycle. Byte 0 is unestablished.

## Cloud Dependency & Home Assistant Guidance

**The device does not need the cloud for anything.** Braun's cloud (AWS
Cognito login, AppSync GraphQL device registry, AWS IoT MQTT telemetry;
Contentful CMS; Firebase/RudderStack/UXCam analytics app-side) buys three
things: account sync of session history, the "flashes available" counter
(which is read from the cloud, not the device), and vendor telemetry from
provisioned Wi-Fi SKUs. A total cloud shutdown leaves the device flashing and
every BLE function working.

For Home Assistant or a custom client: no integration exists yet, but the
whole surface is scan → bond → MTU 515 → three verbs on `3C00`–`3C04`, easily
driven from a small bleak script. Session tracking is the natural polling
loop: mark SESSION_START, watch Push for `0x1003`/`0x1004` (sessions the
device starts and ends on its own), GET SESSION_DATA for the results.

## Tools Used

- [x] jadx (decompile of Braun IPL 3.3.3, versionCode 7067)
- [x] APKPure via apkeep (APK acquisition, 2026-08-29)
- [ ] BLE sniffer / hardware unit — still needed for the open questions below

## Open Questions (need hardware)

- The containing GATT service UUID(s) — enumerate on a real device.
- Do the characteristics refuse an unbonded client? (Bonding is clearly
  intended; mandatory is unproven.)
- Which PL5xxx SKUs carry Wi-Fi vs BLE-only.
- FlatBuffers schema of the Raw stream (`4C00`) — parse code exists in the
  app, schema not extracted.
- What DEVICE_RESET (cmdId 49) actually clears; whether any physical reset
  exists.
- Byte 0 of Push notifications; full DEVICE_DATA layout beyond bytes 2/3/6;
  the skin-tone bucketing table; whether the BLE address is public or
  random-static.

## References

- [Braun IPL on Google Play](https://play.google.com/store/apps/details?id=com.pg.grooming.braun.ipl) — the vendor app this was recovered from
- [Braun Silk-expert Pro 5 service page (Type 6031)](https://service.braun.com/us/en/products/6031) — manuals, parts, head compatibility
- [Braun Silk-expert Pro 5 manual](https://www.manualslib.com/manual/2134553/Braun-Silk-Expert-Pro-5.html) — the on-device safety behaviour (hardware skin-tone gating) and the 400,000-flash lifetime
- Analysis APK: `com.pg.grooming.braun.ipl` v3.3.3 (7067), sha256 `0ad7cfaa1249b64420de941d5467bd260111f365f4fdc86bd2cb4c80bd842b0c`

## Contributors

- Liberated Bread RE workspace — APK acquisition, decompile, protocol recovery
