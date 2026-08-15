# KingSmith WalkingPad

> **Status**: Complete (two protocol generations documented; FTMS supplement channel partial). WiLink read path **hardware-verified 2026-08-14** (status/params/record queries against a live pad; belt-motion commands deliberately untested)
> **Protocol**: BLE
> **Manufacturer**: KingSmith Fitness (Beijing KingSmith Technology, Xiaomi ecosystem)
> **Manufacturer Status**: Active — cloud-independent local control, not an abandonment rescue

## Overview

KingSmith's foldable WalkingPad treadmills (A1, A1 Pro, R1, R1 Pro, R2, C2,
X21, MC21, Z1 and OEM variants) are controlled entirely over local BLE. The
manufacturer is alive and shipping new models in 2026; the reason to document
the protocol is that the official apps (WalkingPad / `com.walkingpad.app`,
KS Fit / `com.kingsmith.xiaojin`) route account, workout history and firmware
update checks through KingSmith's cloud, while the control plane needs none of
it. Several mature open implementations already drive the pads fully offline
(ph4-walkingpad, QWalkingPad, walkingpad-controller + Home Assistant).

Two protocol generations exist, detected by advertised name/service:

| Generation | Models | BLE name prefixes | Transport |
|-----------|--------|-------------------|-----------|
| WiLink (legacy) | A1, A1 Pro, R1 Pro, R2, early C2 | `WalkingPad*`, `KS-R1*` | Private service `0xFE00` |
| FTMS | MC21, X21, KS-HD-* (Z1D…), Zeal OEM | `KS-MC21-*`, `KS-SMC21C-*`, `ZP-ZEALR1-*`, `KS-HD-*` | Standard Fitness Machine Service `0x1826` |

Only one BLE central can be connected at a time; if the official app holds
the connection, other clients cannot connect.

## Hardware

| Property | Value |
|----------|-------|
| Models | WalkingPad A1/A1 Pro, R1/R1 Pro, R2, C2, X21, MC21, Z1; OEM (DYNAMAX, KINGSMITH, Zeal `ZP-ZEALR1`) |
| Chipset | Telink BLE SoC (Telink OTA service `00010203-…-0a0b0c0d1912` present) |
| Radio | BLE 4.x GATT |
| FCC ID | Varies by model/SKU |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` — scan for `0xFE00` or `0x1826`, connect, command |
| Setup AP / advertised name | `WalkingPad*`, `KS-*`, `ZP-ZEALR1-*`, `KINGSMITH*`, `DYNAMAX*` |
| Passphrase protection | not_applicable (no pairing, no authentication) |
| Confidence | high (multiple working open implementations) |

**Factory reset**: not documented for any model; nothing is stored that blocks
local control (no bonds, no credentials). Preferences (max speed, child lock,
units) are writable over the same unauthenticated channel.

**Rebinding**: any client may connect once the previous central disconnects.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0xFE00` | WiLink treadmill service | Legacy models; write `0xFE02`, notify `0xFE01` |
| `0x1826` | Fitness Machine Service | Newer models; standard FTMS |
| `24e2521c-f63b-48ed-85be-c5330b00fdf7` | KingSmith supplement service | KS-HD-* models: properties, user profile, offline records, OTA (roles unmapped) |
| `0x180A` | Device Information | Model/firmware strings |
| `00010203-…-0a0b0c0d1912` | Telink OTA | Firmware update; bricking risk, uncaptured |

### WiLink frame grammar (legacy models)

Both directions: `F7` (phone→pad) / `F8` (pad→phone) header, message-class
byte (`0xA2` control/status, `0xA5` params, `0xA6` preference write, `0xA7`
records), `0xFD` terminator. The penultimate byte is an additive checksum:
`cmd[-2] = sum(cmd[1:-2]) & 0xFF`; the pad silently ignores bad checksums.
Time (s), distance (10 m units) and step counters are 3-byte big-endian
integers. Speed unit is 0.1 km/h. The stock app polls status every ~750 ms;
space commands ≥ ~700 ms apart.

Static evidence in `com.walkingpad.app` v2.5.5 (2026-08-08): `0xFE00/FE01/
FE02` UUID strings plus dedicated builder methods `_setSpeed`, `_setSpeedR1`
(an R1-specific variant) and a `_checkSum` helper are present in `libapp.so`;
frames are built in code, so the checksum algorithm itself is not embedded as
data — it rests on the two independent hardware-confirmed implementations
(ph4-walkingpad, QWalkingPad). The `_setSpeedR1` split hints R1 pads may
deviate from A1 frame details; worth one snoop on R1 hardware.

### Commands (write to `0xFE02`)

| Command | Bytes (checksum shown resolved) | Verification |
|---------|--------------------------------|--------------|
| Query status | `F7 A2 00 00 A2 FD` | confirmed |
| Set speed (0.1 km/h; 0 = stop; 5–60 usable) | `F7 A2 01 <speed> <crc> FD` | confirmed |
| Switch mode (0 auto / 1 manual / 2 standby) | `F7 A2 02 <mode> <crc> FD` | confirmed |
| Start belt | `F7 A2 04 01 A7 FD` | confirmed |
| Calibration mode (advanced) | `F7 A2 03 <enable> <crc> FD` | reported |
| Query preference block | `F7 A5 60 4A 4D 93 71 29 C9 FD` | reported |
| Query last workout record | `F7 A7 AA FF 50 FD` (then `… 00 51 FD` pops next) | confirmed |
| Set preference | `F7 A6 <key> <subtype> <v2> <v1> <v0> <crc> FD` | confirmed |

Preference keys: 1 goal (subtype 0 none / 1 distance / 2 calories / 3 time),
3 max speed (**advanced** — raises the fall-risk ceiling), 4 start speed,
5 auto-start on step-on, 6 sensitivity (1 high / 2 medium / 3 low), 7 display
mask, 8 units (0 metric / 1 imperial), 9 child lock.

### Status frame (notify on `0xFE01`, header `F8 A2`, 19 bytes)

| Offset | Length | Description |
|--------|--------|-------------|
| 0–1 | 2 | Header `F8 A2` |
| 2 | 1 | Belt state |
| 3 | 1 | Speed (0.1 km/h) |
| 4 | 1 | Mode (0 auto / 1 manual) |
| 5–7 | 3 | Time, seconds (big-endian) |
| 8–10 | 3 | Distance, 10 m units (big-endian) |
| 11–13 | 3 | Steps (big-endian) |
| 14 | 1 | Last app-set speed (raw) |
| 15 | 1 | Unknown |
| 16 | 1 | Last remote button (0 none / 2 up / 3 stop / 4 down) |
| 17 | 1 | Checksum |
| 18 | 1 | Terminator `0xFD` |

Worked example (ph4-walkingpad, real hardware):
`f8 a2 01 0f 01 00 0f d1 00 00 ab 00 12 ae 3c 00 00 00 3a fd` = running,
1.5 km/h, manual, 4049 s, 1.71 km, 4782 steps.

A second response shape (header `F8 A7`) carries the last stored workout
record: time at bytes 8–10, distance 11–13, steps 14–16. The belt keeps the
record only briefly and loses it on power cut — fetch promptly after stopping.

### FTMS generation (MC21 / X21 / KS-HD-*)

Standard Fitness Machine Service with KingSmith extensions:

- **Control Point `0x2AD9`**: `SET_TARGET_SPEED` = `02` + uint16-LE km/h×100
  (`02 90 01` = 4.0 km/h — HCI-snoop-confirmed on MC-21), `START_OR_RESUME`
  = `07`, `STOP_OR_PAUSE` = `08 01|02`. `REQUEST_CONTROL` (`00`) is routinely
  rejected by the firmware; the official app ignores the rejection and
  proceeds — do the same.
- **ODM pre-amble**: devices exposing vendor characteristic
  `d18d2c10-c44c-11e8-a355-529269fb1459` require the fixed 8-byte frame
  `01 00 0d 00 06 0b 0f 0d` written before *each* Control Point command, or
  the pad answers `CONTROL_NOT_PERMITTED`. The response carries a device
  property table. The parent service UUID is **verified absent from both app
  binaries** (2026-08-08 string-table enumeration: `d18d2c10` is the only
  `*-c44c-11e8-*` UUID in either app) — the app binds it by GATT enumeration;
  capture the parent service UUID from hardware.
- **Speed opcode discrepancy (resolved)**: the `0x03` set-speed claim comes
  from Ivan Morgillo's **Mobvoi** Home Walking Pad writeup — a different
  vendor, not KingSmith. In FTMS 1.0, `0x02` = Set Target Speed and `0x03` =
  Set Target Inclination. KS Fit v6.5.6 has separate `setSpeed`/
  `setInclination` paths (string table), so on incline models (X21) it emits
  `0x03` for *inclination* only. WalkingPad app v2.5.5 has no FTMS strings at
  all (WiLink-only). KingSmith speed opcode is `0x02`, HCI-snoop-confirmed
  on MC-21.
- **Treadmill Data `0x2ACD`**: standard flags-gated fields; KingSmith adds a
  step counter as flag bit 13.
- **Status `0x2ADA`**: KS Fit decodes a "safe_off list" from 0x2ADA events
  (log strings `2ADA safe_off list = ` / `2ada: device status change: `) —
  hypothesis: the subset of FTMS status opcodes meaning "belt safely stopped"
  (0x03 stopped/paused by user, 0x04 stopped by safety key, vs 0x02
  started/resumed). Exact opcode set needs a snoop.
- **Supplement service** `24e2521c-…` on KS-HD-* models: property list, user
  profile, units, offline records, presets and OTA; frames use body +
  1-byte additive checksum. Four characteristics exist in the v6.5.6 binary
  (`…0b/0d/0e/0f00fdf7`); `0b` and `0d` are referenced by active code
  (byte-reversed comparison constants `f7fd000b-…`/`f7fd000d-…`), `0e`/`0f`
  are table-only entries. Per-characteristic roles still unmapped (needs
  snoop).

## Safety

This is motorised exercise equipment with **no authentication** on either
protocol: anyone in BLE range can start the belt or change its speed. Max-speed
and calibration writes change the mapping between commands and real belt
speed — flagged `advanced` in the spec. WiLink models have a child-lock
preference (key 9).

## Cloud dependency

None for control. KingSmith cloud is used by the apps for account login (JWT),
workout-history sync and OTA notification only. If the cloud disappears,
everything in this spec keeps working.

## App Provenance

| App | Package | Version | Source | SHA-256 |
|-----|---------|---------|--------|---------|
| WalkingPad | `com.walkingpad.app` | 2.5.5 | APKPure via apkeep | `cf3309e38a8c9a432f04dcf259c21c21c2d6178dec1057f952a18659d3a3053a` |
| KS Fit | `com.kingsmith.xiaojin` | 6.5.6 (5291) | APKPure via apkeep (XAPK) | `a889584a6159b6dc801bc99d62ff7e5b7fcce05b8599a10a3fb6ef6465060914` |

Both are Flutter apps (Dart AOT `libapp.so`); string analysis of the binaries
confirms every UUID above and the model name prefixes. Deeper Dart-level RE
of KS Fit was published by mcdax (blutter) — see references. SHA-256 of both
local APK copies re-verified against this table 2026-08-08 (exact match).
Note: KS Fit 6.5.6 ships native code in a `config.armeabi_v7a` split only
(32-bit `libapp.so`); the WalkingPad app ships arm64-v8a. The WalkingPad app
is WiLink-generation only — no FTMS UUIDs in its string table.

## Tools Used

- [x] APK fetch (apkeep / APKPure) and string analysis of `libapp.so` (both apps, 2026-08-08 pass: full UUID enumeration, supplement-channel active-path evidence, opcode-discrepancy resolution)
- [x] Prior-art protocol implementations (ph4-walkingpad, QWalkingPad, walkingpad-controller) cross-checked against app binaries
- [ ] HCI snoop (needed for: supplement-service per-char roles/properties, `0x2ADA` "safe_off" opcode set, ODM parent service UUID, R1 `_setSpeedR1` frame variant — see `research-notes/kingsmith-walkingpad-capture-plan.md`)

## References

- [ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad) — original WiLink RE + Python controller
- [DorianRudolph/QWalkingPad](https://github.com/DorianRudolph/QWalkingPad) — independent GPL C++ implementation
- [mcdax/walkingpad-controller](https://github.com/mcdax/walkingpad-controller) — active FTMS+WiLink Python library; [KS Fit RE log](https://github.com/mcdax/walkingpad-controller/blob/main/docs/ks-fit-reverse-engineering.md)
- [darnfish/walkingpad](https://github.com/darnfish/walkingpad) — JavaScript client
- [KingSmith official site](https://www.kingsmith.com/) — manufacturer status (active, 2026)

## Contributors

- Spec assembled from public prior art, verified against official app binaries (apkeep + jadx/strings), 2026-08-04
