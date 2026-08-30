# UREVO Walking Pad

> **Status**: In Progress (frame grammar + command set recovered from the app binary; nothing hardware-confirmed yet)
> **Protocol**: BLE
> **Manufacturer**: UREVO (urevosports.com)
> **Manufacturer Status**: Active — cloud-independence spec, not an abandonment rescue

## Overview

UREVO's under-desk treadmills / walking pads (SpaceWalk, Strol, CyberPad
retail families; model numbers seen in the app: URTM012, URTM018, URTM022,
URTM023, URTM024, URTM029, URTM030, URTM041, SYWP006) are controlled over
local BLE by the official UREVO app (`com.urevo.app`, Flutter). The app
routes account, workout history, OTA and per-model metadata through the
UREVO cloud; the control plane itself is plain BLE GATT with no pairing or
authentication visible in any treadmill code path.

The app multiplexes three treadmill protocol stacks
(`package:urevo_bluetooth`, `EquipmentFactory`):

| Class | Identification | Transport | Frame grammar |
|-------|----------------|-----------|---------------|
| FTMS | Advertised service `0x1826` | Standard Fitness Machine Service | Standard FTMS 1.0 |
| FT proprietary | Service `0xFFF0` (write `0xFFF2`, notify `0xFFF1`) | Private GATT | BluePack A (`02 … 03`, XOR-0x5A checksum) |
| UR proprietary | Name prefixes `URTM*` / `SYWP*` | GATT endpoints **not in the binary** — enumerate on device | BluePack A (cmd class `0x53`) + BluePack B (`5A A5 …`) |

**KingSmith cross-check**: no relationship. The KingSmith WiLink service
`0xFE00`, ODM characteristic `d18d2c10-…` and supplement service
`24e2521c-…` are all absent from the UREVO binary, and the frame grammars
share nothing. The only overlap is that both brands ship FTMS-generation
models. UREVO gets its own spec.

The same app also drives UREVO massagers (`UCRM*` names, services `0xFFF0`
and `0xFEE0`) and smart scales (`WSEquipment`, factory matcher key
`55525753` = ASCII "URWS") — out of scope here.

## Hardware

| Property | Value |
|----------|-------|
| Models | URTM012/018/022/023/024/029/030/041, SYWP006 (from app model tables) |
| Chipset | Unknown (no OTA-service UUID identified in the binary) |
| Radio | BLE GATT |
| FCC ID | Varies by model/SKU |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` — scan, connect, command |
| Setup AP / advertised name | `URTM*` / `SYWP*` (UR), service `0x1826` (FTMS), service `0xFFF0` (FT) |
| Passphrase protection | not_applicable (no pairing/auth found in treadmill classes) |
| Confidence | medium (static analysis only — no hardware capture yet) |

**Factory reset**: nothing recoverable from the app binary for treadmills
(the massager classes have a factory-settings command; treadmills don't).
The pads hold no network credentials or bonds, so there is nothing to
clear for local control.

**Rebinding**: any client may connect once the previous central
disconnects (single-connection peripheral, as typical for the class;
unconfirmed on UREVO hardware).

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0x1826` | Fitness Machine Service | FTMS models; standard characteristics below |
| `0xFFF0` | BluePack proprietary service | FT class; write `0xFFF2`, notify `0xFFF1` |
| `0x180A` | Device Information | Model/serial/firmware strings `0x2A23`–`0x2A29` |
| (unknown) | UR-class service | UR treadmills (`URTM*`/`SYWP*`); **no UUID constants in the binary** — capture from hardware |

FTMS characteristic set (confirmed by the class's UUID getters in
`libapp.so` v3.6.22): write `0x2AD9` (Control Point), notify `0x2ACD`
(Treadmill Data), `0x2ADA` (Fitness Machine Status), `0x2AD3` (Training
Status); read `0x2AD4` (Supported Speed Range), `0x2AD5` (Supported
Inclination Range). No vendor pre-amble or private characteristic exists
in this path. The app builds FTMS frames in code; assume the standard
FTMS 1.0 opcode set (`00` Request Control, `02` Set Target Speed as
uint16-LE 0.01 km/h, `07` Start/Resume, `08` Stop/Pause) until an HCI
snoop confirms what it actually emits.

### BluePack A frame grammar (FT + UR classes)

Both directions, recovered from the BluePack A serialiser, its factory,
and its checksum helper:

```
02 <cmd> <sub> <payload...> <checksum> 03
checksum = (cmd + sub + sum(payload)) & 0xFF ^ 0x5A
```

`cmd` is the command class (`0x44` FT equipment, `0x53` UR treadmill,
`0x50` config query, `0x51` status query); `sub` is the action within the
class and is omitted on the `0x51` status query. The factory dispatches
inbound frames on `first == 0x02 && last == 0x03`.

A second family, BluePack B, carries version/OTA traffic. Fully recovered
from the `BluePackB` constructor, `toUInt8List`, `fromUInt8List` and
`crc16CCITT`:

```
5A A5 <f1> <f2> <f3> <cmd> <sub> <len u16-LE> <data…> <crc u16-LE>
crc = CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, MSB-first, no final XOR)
      over all preceding bytes including the 5A A5 header, appended little-endian
```

`f1`–`f3` are three 1-byte header fields (`01 03 00` in the version query;
semantics unidentified). `len` is the uint16-LE data byte count. The
inbound parser rejects frames shorter than 11 bytes or with a bad CRC.

### Commands (write to `0xFFF2` on FT class; UR endpoint TBD)

All bytes recovered by disassembling the app's command builders (ARM,
`libapp.so` v3.6.22); checksums shown resolved. **None of these have been
sent to real hardware yet.**

| Command | Bytes | Verification |
|---------|-------|--------------|
| FT: prepared | `02 44 01 1F 03` | reported (static) |
| FT: stop | `02 44 04 12 03` | reported (static) |
| UR: training prepared | `02 53 01 0E 03` | reported (static) |
| UR: set speed + slope | `02 53 02 <speed> <slope> <chk> 03` | reported (static) |
| UR: training stop | `02 53 03 0C 03` | reported (static) |
| UR: training continue | `02 53 09 06 03` | reported (static) |
| UR: training pause | `02 53 0A 07 03` | reported (static) |
| UR: get speed config | `02 50 02 08 03` | reported (static) |
| UR: get slope config | `02 50 03 09 03` | reported (static) |
| UR: get equipment status | `02 51 0B 03` (no sub byte) | reported (static) |
| UR: get controller version | `5A A5 01 03 00 10 01 00 00 8C 6F` (BluePack B) | reported (static) |

Speed and slope are integer counts derived from the display value via
`BlueNumExt.fromKmh`/`fromSlope`, which divide by a per-unit factor from
the app's runtime unit-config map (keys `kmh`/`slope`, default `1.0`).
The absolute step (likely 0.1 km/h) is therefore not a binary constant —
read the speed-config response first to learn it.

### Responses

Inbound frames arrive on the notify characteristic (`0xFFF1` on FT class).
`ResponseFactory.createResponse` dispatches on a key of
`<EquipmentClassName>_<cmdhex><subhex>`; treadmill answers carry the same
command class as the request. Recovered dispatch table:

| Key | Parser class |
|-----|--------------|
| `51` (no sub) | `TMStatusResponse` |
| `53 01` | `TMPreparedResponse` |
| `53 02` | `TMSetSpeedAndSlopeResponse` |
| `53 03` | `TMStopResponse` |
| `53 04` | `TMBlueStateResponse` |
| `53 09` | `TMStartResponse` |
| `53 0A` | `TMPauseResponse` |
| `50 00` | `TMVersionInfoResponse` |
| `50 02` | `TMSpeedConfigResponse` |
| `50 03` | `TMSlopeAndConfigResponse` |
| `50 04` | `TMMileageResponse` |
| `53 10` / `53 11` | `TMGet/SetDotMatrixScreenResponse` (UR class only) |
| `10 01` (BluePack B) | `OTAMajorVersionResponse` |

FT and UR treadmill keys share the same parser classes. Keys `50 00`,
`50 04`, `53 04` and the dot-matrix pair have no matching command builders
found in `UREquipment` — treat them as response-only until a sender is
confirmed on hardware. Command class `0x40` (previously unidentified)
belongs to a separate "CM" product family (`CMSetLightResponse`,
`CMGetLightInfoResponse`, `CMGet/SetSwitchConfigResponse`,
`CMGetElectricalStudyResponse`) — not treadmills. Per-field offsets inside
the responses are not yet recovered — needs an HCI snoop or further
disassembly of the per-class `onParseData` parsers.

## Safety

Motorised exercise equipment with no authentication on the BLE link: once
the command bytes above are confirmed, anyone in radio range can start the
belt or change its speed. Treat the static-analysis command set as
unproven until exercised on hardware; verify the stop command first.

## Cloud dependency

None for control once the GATT endpoints are known. The UR class's
endpoint/config discovery leans on per-model cloud config (`DeviceConfig`)
— capture the endpoints once and the cloud is out of the loop. Account,
history sync and OTA are cloud-only features. App-side cloud surface seen
in the binary (the pad itself contacts none of it):

- API hosts: `https://service.urevosports.com`, `https://urevo.urevosports.com`;
  H5 pages on `https://h5.urevosports.com`
- Two hardcoded plain-HTTP IP endpoints: `http://106.52.219.41:8082`,
  `http://81.71.103.167` (likely legacy/fallback API hosts)
- OTA metadata: `/product/api/ota/otaCheckVersion` (plus `getProductAll`,
  `addUpdateLog`, `addConnectLog`); history sync under `/data/api/…`;
  scale API under `/api/service-scale/…`

## App Provenance

| App | Package | Version | Source | SHA-256 |
|-----|---------|---------|--------|---------|
| UREVO | `com.urevo.app` | 3.6.22 (26042201) | APK | `3b39a90854c463f7b8cff7bf0a95562aba401c71c5a43e08287aec28d5f56f17` |
| UREVO | `com.urevo.app` | 3.6.22 | XAPK (bundle; armeabi_v7a `libapp.so` analysed) | `c446b0200ffb27e7bed720293dab5ad4bbe79d9008635673b363239821a4ab63` |

Flutter app; the BLE stack is Dart AOT in `libapp.so`
(`package:urevo_bluetooth`). Analysis method: Dart 3.4.3 cluster snapshot
parse + ARM disassembly of the protocol functions (custom tooling; jadx
for the Java/manifest layer).

## Tools Used

- [x] APK/XAPK string analysis + jadx (Java layer, manifest)
- [x] Dart AOT snapshot parse + targeted ARM disassembly (frame grammar, checksum, command bytes, UUID getters, response dispatch table, BluePack B layout + CRC)
- [ ] HCI snoop on hardware (needed for: UR-class service/characteristic UUIDs, FTMS opcode set actually emitted, response field offsets, speed-step value)

## References

- [UREVO official site](https://www.urevosports.com/) — manufacturer status (active, 2026)
- [UREVO app on Google Play](https://play.google.com/store/apps/details?id=com.urevo.app) — protocol source

## Contributors

- Spec derived from static analysis of `com.urevo.app` v3.6.22 (clean-room; no vendor assets copied), 2026-08-12
