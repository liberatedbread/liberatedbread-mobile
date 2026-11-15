# Hyperice Hypervolt Plus

> **Status**: Research
> **Protocol**: BLE
> **Manufacturer**: Hyperice, Inc.
> **Manufacturer Status**: Active (healthy; no cloud-shutdown risk — and the device needs no cloud anyway)

## Overview

The Hypervolt Plus (Bluetooth) is a 90 W percussion massage gun — 3 speeds,
5 heads — and the BLE-connected variant of the original Hypervolt. It was
reverse engineered by decompiling the current vendor Android app
(`com.hyperice.app` 2.7.0) in August 2026. All control is local BLE; the
cloud only serves the app's account, guided-routine library and firmware
metadata. One protocol covers the whole legacy family: Hypervolt, Hypervolt
Plus, Hypervolt 2 / 2 Pro, and the Vyper 3 / Vyper Go rollers. (The newer
Hypervolt 3, Normatec, Venom 2 and Hyperice X families in the same app use
different UUIDs and are out of scope here.)

## Hardware

| Property | Value |
|----------|-------|
| Model Number | 54020 001-00 (per device.report listing) |
| Chipset | Unknown (Nordic-based, per sibling products' FCC filings) |
| Radio | BLE |
| FCC ID | Not confirmed; Hyperice's grantee code is 2AY3Y (sibling filings) |

## Initial Setup

Nothing to provision — no network, no account, no cloud. The gun works
standalone from its physical speed button; BLE adds app control.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `HV+;` (legacy family: `HV;`, `HV2;`, `HV2P;`, `VY3;`, `VYGO;`) |
| Passphrase protection | not_applicable |
| Confidence | low (derived from decompiled app, not replayed on hardware) |

The one wrinkle is a per-connection handshake: after connecting, read the
"secure" characteristic, take its last 3 bytes as a seed, and — unless the
seed reads back `00 00 00` — derive a 4-byte password from the seed and the
device MAC (algorithm in the YAML spec) and write it back with response.
Whether fresh units answer with an all-zero seed, making the password write
unnecessary, is the top open question.

**Factory reset**: no reset procedure was found in the app, and the pairing
model (a per-connection derived password rather than a stored bond) suggests
there may be nothing persistent to clear. Whether a hardware button-combo
reset exists is unknown.

**Rebinding to a new controller**: trivial — BLE-only, no network binding. A
new phone or Home Assistant instance just scans, connects and handshakes. If
a unit refuses to connect, the usual cause is another client (often the
vendor app) still holding the single BLE connection.

## Protocol Summary

### BLE Services

Two custom characteristics under a `31CB45xx-3C31-4E56-8C2B-E8F479D2B056`
base (containing service UUID not pinned in the app — clients should match
the characteristics), plus the standard Device Information Service.

| UUID | Name | Properties | Description |
|------|------|------------|-------------|
| `31CB4570-…` | Secure | R / W-with-response | Read: session seed (last 3 bytes). Write: derived 4-byte password `{01, b1, b2, b3}` |
| `31CB456C-…` | Level Control | Notify / W-without-response | Single-byte percussion level, both directions |
| `00002A26` | Firmware Revision | R | Standard DIS |
| `00002A25` | Serial Number | R | Standard DIS |
| `00002A27` | Hardware Revision | R | Standard DIS |
| `00002A28` | Software Revision | R | Standard DIS |

There is **no battery characteristic** (the LED ring shows charge) and **no
OTA/DFU path** on this family.

### Commands

#### Command: Stop / reset level

**Request** (write without response to `31CB456C-…`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x00` |

#### Command: Set level

**Request** (write without response to `31CB456C-…`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Level, expected 0–3 (0 = off + 3 hardware speeds; range unverified) |

#### Command: Session password

**Request** (write *with* response to `31CB4570-…`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Constant `0x01` |
| 1 | 3 | Derived from the device MAC and the 3-byte seed via a fixed 256-entry lookup table (full algorithm in the YAML spec) |

**Response / state**: notifications on `31CB456C-…` carry the current level
as one byte. Whether they echo the commanded speed or a force-sensor pressure
band is unverified.

### Discovery

- Advertised local name starts with `HV+;` (case-insensitive, note the
  trailing semicolon)
- Bluetooth SIG company ID `0x08BA` (2234, Hyperice) as a secondary signal
- The vendor app connects with a 15 s timeout and 7 retries

## Cloud Dependency

**None for control.** The cloud (`app.hyperice.com/v1`, Okta-issued JWT,
alive as of 2026-08-18) serves the account, the guided "HyperSmart" routine
library, routine-completion sync, and firmware-update metadata — all
phone-side features. If it disappeared tomorrow the gun would lose nothing:
it runs standalone from its button and remains fully controllable over BLE.

For Home Assistant users there is therefore nothing to keep alive — no DNS
redirect, no blocking rules needed. An `esphome_ble_client` integration is
straightforward: read the seed, run the documented derivation, write the
password, subscribe and write single-byte levels. The only hardware check
still needed is whether the seed read returns `00 00 00` on a fresh unit,
which would let the handshake be skipped entirely.

## Tools Used

- [x] APK decompilation (jadx)
- [ ] Hardware capture — not yet done; everything here is static analysis

## References

- [Hyperice app on Google Play](https://play.google.com/store/apps/details?id=com.hyperice.app) — the analysed app (v2.7.0)
- [Hypervolt Plus product page](https://hyperice.com/products/hypervolt-plus/) — hardware specs
- [Hyperice on device.report](https://device.report/hyperice) — model number listing

## Contributors

- Liberated Bread research pipeline — initial research (2026-08-18)
