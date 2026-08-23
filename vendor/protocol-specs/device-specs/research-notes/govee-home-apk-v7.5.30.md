# Govee Home APK v7.5.30 — analysis notes

Static analysis of `com.govee.home` v7.5.30 (versionCode 1097, minSdk 28,
targetSdk 36), fetched via apkeep into `workspace/apks/apkeep/` and
decompiled with jadx into `workspace/govee_apk/jadx/` (both gitignored).
Extraction integrity: the standalone `.apk` and the base apk inside the
`.xapk` are byte-identical (SHA-256
`34c0abdaeac4b3ace85bce10d4721f4be6a5696ae6fbc0fe8e0c01e4da529855`); zip
integrity clean; 14 dex files; jadx reported 153 failed classes out of
36,480 (normal for obfuscated apps).

Per clean-room rules this note describes app components by role, not by
internal name. Package/class names appear nowhere here on purpose; the
decompile tree is local if a future pass needs to re-trace a claim.

## What the app tells us about the wire protocols

### One command channel to rule them all

Every connected Govee light family except the H6101/H6104 pair uses:

- service `00010203-0405-0607-0809-0a0b0c0d1910`
- one characteristic `…2b11` for write **and** notify (CCCD 0x2902)
- 20-byte fixed frames: `[0]=0x33 write / 0xAA read / 0x3A write-read,
  [1]=command, [2..18]=payload, [19]=XOR(0..18)`

H6101/H6104 use `0xFFE0/0xFFE1` with the same framing. The app's group
control writes to FFE0/FFE1 for those two models and falls back to it on
other families only when the 1910 service is missing.

There is **no per-SKU UUID configuration**: the runtime-configurable
channel in the app's newer architecture defaults to 1910/2b11 and no SKU
overrides it. A cloud-delivered BLE profile does not exist in this build.

The full opcode map, sub-modes, multi-packet (`0xA3`) framing, notify
(`0xEE`) subtypes, auth (`AA B1` / `33 B2`, 8-byte key on lights, 16-byte
on plugs) and the AES session layer are written up in
`device-specs/devices/govee-rgbic-light.yaml`; the plain-RGB subset in
`govee-rgb-light.yaml`; FFE0 in `govee-h6101-backlight.yaml`.

### Service 1912 / char 2b12 is OTA, not control

On Telink-based units (hardware version string `1.xx.xx`) the service
`00010203-…-1912` with characteristic `…2b12` is the firmware-update
channel: write `01 FF` to start, fixed packets, end frame
`02 FF <index LE> <~index LE> 00 00`. Other hardware generations use
Beken (`F000FFC0-…/FFC1/FFC2`, hw `2.01.xx`), Freqchip (`02f00000-…-fe00`,
hw `3.xx.xx`), or legacy `fd00/fd01/fd02` (H605x hollow lamps).

**The same `…2b12` UUID on service `…1910`** is a different thing: the
"BGC info" read that announces the encryption version (see the AES layer
section in the rgbic spec). Absent characteristic = plaintext protocol.

### The app contains no LAN client

Zero UDP/multicast/SSDP/mDNS code outside the bundled media player. The
publicly documented Govee LAN API (UDP 4001/4002/4003, `scan`,
`devStatus`, `onOff`, `brightness`, `colorwc`, `pt`/`ptReal`) is purely
device-firmware-side. The app only *enables* it:

- per-device WiFi function list (bit 4 = local network API), read over
  BLE or cloud, gated by hardcoded minimum firmware versions per
  goodsType;
- the toggle is a BLE-protocol frame (write type `0xE3`, sub `0x01`,
  payload `0x00/0x01`; read type `0xEA`) deliverable over BLE or cloud
  IoT.

Cloud IoT commands (`turn`, `brightness`, `color`, `colorwc`, `pt`,
`ptReal`, …) tunnel **base64 of the standard 20-byte BLE frames** inside
`{"msg":{…}}` JSON over AWS IoT MQTT — the BLE frame set is the shared
vocabulary across all three transports (BLE, cloud, LAN).

WiFi provisioning is a BLE write (command `0x11`, multi-packet):
`[ssidLen][ssid][pwdLen][pwd][runMode][tzH][iotVersion][tzM]` plus
optional Matter/security extensions. Fallback: device softAP
(`Govee_bulb_<sku>` on bulbs, `Govee_gateway` on gateways) hosting a TCP
provisioning socket on `192.168.1.1:7200` / `192.168.4.1:8200` with a
10-byte `AA 33`-header JSON protocol. `10.10.100.254` does not occur.

### Advertisement parsing

The broadcast parser walks raw AD structures:

- company id `0xEC88` (bytes `88 EC` in the mfg AD payload);
- one variant carries a leading byte before the company id whose low
  nibble is the broadcast-protocol version; goodsType is 2 bytes
  big-endian at AD payload offsets 3-4; state bytes follow (layout
  varies: on/off at offsets 8-9, battery/charge bitfield at 9, …);
- thermo-hygrometers additionally require a `03 03 88 EC` service-UUID
  AD structure (16-bit UUID 0xEC88) and pack temp/humidity into 3 bytes
  (`temp_deci°C = v/1000*10`, `hum_deci% = v%1000*10`, MSB = negative);
- advertised name forms: `ihoment_<sku>_<suffix>`, `Govee_<sku>_…`,
  `Minger_<sku>_…`, `GBK_<sku>_…`, `GVH<sku><4 hex>` or
  `GVH<sku>_<suffix>`, `GV<5 digits>` (→ `H<digits>`).

The SKU→goodsType map is cloud-delivered with a hardcoded fallback table;
`assets/categories.json` in the APK carries the full consumer-facing SKU
catalog (533 light SKUs extracted to `workspace/govee_apk/light-skus.tsv`).

## The nearby mystery device (a Telink `A4:C1:38:…` unit) — RESOLVED

A connect-and-read from the user's machine (2026-08-22,
`scripts/govee_ble_probe.py`) settled it: **not a Govee at all**. The
Device Information service reports manufacturer `miaomiaoce.com`, model
`LYWSD03MMC`, firmware `github.com/pvvx` — a Xiaomi thermo-hygrometer
running the pvvx ATC custom firmware v5.8, advertising as `ATC_<mac tail>`.
The A4:C1:38 OUI is **Telink Semiconductor's**, shared by Xiaomi and
Govee hardware alike, which is what invited the misidentification.

Its advertisement carries only BTHome v2 service data under 0xFCD2
(decoded live: battery 92 %, 23.81 °C, 59.93 % RH, matching the GATT
reads); 0x181A appears only in the connected GATT table. The
`xiaomi-lywsd03mmc` spec's discovery matcher listed only 0x181A — fixed
to include 0xFCD2. This also explains a "no spec matched" report from a
consumer app: the processed advertisement had no local name and no
0x181A, so neither matcher arm could fire.

## Govee lights on the air (2026-08-22 scan, user's machine)

Four units seen, all WiFi lights named `Govee_<sku>_<mac tail>` with NO
advertised service UUIDs (name suffixes are this machine's own units'
MAC tails, placeholdered):

| Name | Parsed company id | Manufacturer payload |
|---|---|---|
| Govee_H6076_XXXX | 0x8843 | `43 88 ec 00 02 01 00` |
| Govee_H6076_YYYY | 0x8802 | `02 88 ec 00 01 01 00` |
| Govee_H607C_XXXX | 0x8803 | `03 88 ec 00 01 01 01` |
| Govee_H6099_XXXX | 0x8803 | `03 88 ec 00 01 01 01` |

Confirms the version-byte-first layout: the parsed "company id" is
`0x88XX` (low nibble = broadcast version; 0x43 has the 0x40 flag bit
set), the real marker `88 EC` sits at payload offset 1. Note the two
bytes after `88 EC` are `00 01` / `00 02` — these match NO catalog
goodsType (H6076=69, H607C=209, H6099=191 in the app's SKU table), and
two H6076 units even differ, so on WiFi lights that field is not a model
id; the model comes from the local name. Trailing bytes look like state
(on/off). H6076 (Floor Lamp Basic), H607C (Floor Lamp 2) and H6099 (TV
Backlight 3 Lite) are now variant rows in `govee-rgbic-light.yaml`.

## Clean-room notes

- The AES handshake keys are embedded in the app's resources as encrypted
  hex strings. They were located but deliberately **not** extracted or
  committed; the spec documents the mechanism only.
- Cloud "new scene"/DreamView effect payloads are server-generated blobs
  the app relays verbatim; a clean-room client can only replay captured
  blobs, and the specs say so.
