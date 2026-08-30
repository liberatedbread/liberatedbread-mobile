# Braun Silk-expert Pro 5 (IPL) — Research Notes

## What This Is

The Braun Silk-expert Pro 5 (PL5xxx) is a mains-powered IPL hair-removal
device with BLE (and, on some SKUs, Wi-Fi). Companion app: **Braun IPL**
(`com.pg.grooming.braun.ipl`), analyzed at version **3.3.3 (versionCode
7067)**, sha256 of base APK
`0ad7cfaa1249b64420de941d5467bd260111f365f4fdc86bd2cb4c80bd842b0c`.

Headline: **the device is fully functional standalone.** The app never fires
flashes or gates intensity — over BLE it does session bookkeeping (start /
pause / resume / finish markers), reads back session results (skin tone,
mounted head, energy level, flash count), triggers skin-tone measurement, and
provisions Wi-Fi. There is **no activation/lock step** (contrast FOREO Peach
2). BLE commands carry no credential; only standard BLE bonding (encrypted
link) is expected.

## Transport

- BLE GATT via a P&G "grooming core" SDK (RxAndroidBle). Some SKUs also have
  Wi-Fi (provisioned over BLE, then device phones home via AWS IoT MQTT).
- Discovery: no scan filter; the app parses the **manufacturer-data AD
  structure** (`0xFF`) from scan records: bytes 2–3 = company ID
  little-endian (P&G = `0x00DC`), byte 4 = BLE protocol version (`0x65` seen),
  byte 5 = device type; accepted type **`0x61`** ("Victoria3" = Silk-expert
  Pro 5 generation).
- Connect with autoConnect=false, negotiate **MTU 515**, then subscribe to
  Status/Push/Raw notifications and Read indications. App explicitly bonds
  (`BOND_BONDED` tracked; device has a `BONDING` operation state).

## GATT map

All characteristics are 128-bit UUIDs on the template
**`A0F0XXXX-5047-4D53-8208-4F72616C2D42`** (`XXXX` below):

| UUID suffix | Name | Access | Role |
|---|---|---|---|
| `3C00` | Command | write | All command opcodes |
| `3C01` | Read | read + indicate | Responses to GET commands; live state |
| `3C02` | Write | write | Payload for SET commands (UTF-8: SSID, password, certs) |
| `3C03` | Status | notify | Command acks, 3 bytes `{opcode, cmdId, status}` (0=OK, 1=BUSY, 2=ERROR) |
| `3C04` | Push | notify | Unsolicited events |
| `4C00` | Raw | notify | FlatBuffers raw sensor stream (IMU, skin/contact sensors, temperature, shot count) |

## Command protocol

Three verbs written to `3C00`, no crypto/checksum/framing beyond the opcode:

- **GET** — write `{0xC0, cmdId}`, read response from `3C01`.
- **SET** — write `{0xC1, cmdId}`, write payload bytes to `3C02`, commit with
  `{0xC2, cmdId}`.
- **EXECUTE** — write `{0xC3, cmdId}`, await Status notify
  `{0xC3, cmdId, status}`.

### Operational opcodes (subset the app wires up)

| cmdId | Name | Notes |
|---|---|---|
| 2 | DEVICE_VERSION | hex string |
| 3 | DEVICE_DATA | state bytes (below) |
| 4 | SESSION_DATA | session struct (below) |
| 5 | MEASURE_SKIN_TONE | trigger skin-tone measurement |
| 6 | ENTER_PROVISIONING | enter Wi-Fi provisioning mode |
| 7 / 8 / 9 / 10 | SESSION_START / FINISH / PAUSE / RESUME | session markers |
| 11 | START_PATCH_TEST | |
| 12 | OTA_UPDATE_START | |
| 49 | DEVICE_RESET | |
| 50 | PROTOCOL_NAME | UTF-8 |
| 51 | READ_RAW | enable raw stream |

Provisioning opcodes (separate namespace): WIFI_SSID=2, WIFI_PSWD=3,
TEST_WIFI=4, HOST_PORT=5, AWS_KEY=6, AWS_CERT=7, AWS_ROOT_CA=8, END_CONFIG=9,
WIFI_AP_LIST=10 (35-byte records: SSID 0–32, RSSI 33, encryption 34),
DEVICE_UUID=11, TIMEZONE=13, THING_NAME=14.

### SESSION_DATA (GET 4) layout

| Bytes | Meaning |
|---|---|
| 0 | operation state: 3=IDLE, 4=BONDING, 5=PROVISIONING, 6=SKIN_TONE_MEASUREMENT, 7=SESSION_RUNNING, 9=PATCH_TEST, 10=OTA, 255=NOT_SET |
| 1–16 | session UUID (two big-endian longs) |
| 17 | mounted head: 0=none, 1–31 standard, 33–63 precision, 65–95 large, 97–103 mini-precision, 129–135 smart-flex |
| 18 | energy level: 0=NORMAL, 1=SENSITIVE, 2=EXTRA_SENSITIVE, 255=NOT_SET |
| 19–20 | skin tone, BE u16 (raw; app buckets into 10 tones) |
| 21–22 | flashes fired this session, BE u16 |

DEVICE_DATA (GET 3): byte 2 = device state (0=FACTORY, 1=BONDED, 2=NORMAL,
3=OTA_READY, 254=UNRECOVERABLE_ERROR), byte 3 = Wi-Fi state, byte 6 = raw
stream enabled.

Push events (`3C04`): byte 1 = command value, bytes 2–3 = BE u16 reason —
1/2 = command end success/fail, 0x1003/0x1004 = session started/ended **by
device**, 0x1005–0x1007 = OTA lifecycle, 0x1001/0x1002 = standby/sleep.

## Cloud surface (optional)

- AWS Cognito (login) + AWS AppSync GraphQL (device registry) + a P&G
  discovery API; Contentful CMS; Firebase/RudderStack/UXCam analytics.
- **Wi-Fi provisioning is cloud-gated**: the app obtains per-device AWS
  key/cert from GraphQL and writes them over BLE. Skip provisioning and the
  device simply never talks to the cloud — BLE session tracking is unaffected.
- The "flashes available" counter is read from the **cloud**, so that one
  screen needs a provisioned device + account; everything on-device does not.
- BLE commands carry no auth token; nothing in the BLE layer references
  credentials.

## Feasibility

- **Replacement app: straightforward.** Scan for manufacturer-data device type
  `0x61`, bond, MTU 515, speak GET/SET/EXECUTE on `3C00`–`3C04`. Full session
  tracking, skin-tone readout, head/energy state, and even standalone Wi-Fi
  provisioning (write your own MQTT endpoint instead of AWS) are reproducible.
- Device flashes standalone regardless — no unlock step needed at all.

## Evidence

- App: Braun IPL 3.3.3 (7067), base APK sha256
  `0ad7cfaa1249b64420de941d5467bd260111f365f4fdc86bd2cb4c80bd842b0c`
  (APKPure via apkeep, 2026-08-29).
- Decompile + working notes: `~/research/ipl/` (not committed).

## Open questions

- Whether GATT characteristics actually require an encrypted (bonded) link —
  inferred from explicit bonding + BONDING state; confirm with HCI snoop.
- Which PL5xxx SKUs have Wi-Fi vs BLE-only.
- Raw FlatBuffers schema details (schema not extracted; parse code exists).
