# FOREO Peach 2 (IPL hair removal)

> **Status**: In Progress (protocol fully mapped from the decompiled app; not yet replayed against hardware by this project)
> **Protocol**: BLE (custom GATT, Telink-based)
> **Manufacturer**: FOREO AB
> **Manufacturer Status**: Active — but the device's cloud touchpoints are bookkeeping only; nothing about control needs them

## Overview

The FOREO Peach 2 is a mains-powered IPL (intense pulsed light) hair-removal
device with BLE, driven by the *FOREO For You* app. This page covers the whole
family — Peach 2, Peach 2 go, Peach 2 Pro MAX, Peach 2 Duo — which shares one
code path in the app (analysed: `com.foreo.foreoapp` 4.4.1 / versionCode 559).

Two findings make this device unusually liberate-friendly:

1. **The ship-lock unlocks offline.** The device ships locked and will not
   turn on until it is "registered" from the app. The stock app does that with
   an account login and a server call — but the bytes that actually unlock the
   firmware are a **keyless permutation of the device's own BLE MAC address**,
   computed locally. The server call is warranty bookkeeping; a replacement
   client can activate a brand-new unit with zero network access.
2. **The "Pro" paywall is app-side only.** Pro removal mode is gated in the
   app behind a server-side subscription, but the firmware accepts the
   Pro-mode command (`0AD0 06`) unconditionally — no credential, no check.
   Enforcement is literally the app writing Basic mode back when it finds the
   device in Pro without a subscription. Intensity and Basic mode are not
   paywalled at all.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | FOREO Peach 2 (family: Peach 2 / go / Pro MAX / Duo) |
| Chipset | Telink-based BLE SoC |
| Radio | BLE only — no Wi-Fi |
| Optical output | Up to 7.3 J/cm²; skin-contact and eye-safety interlocks in firmware |
| FCC ID | Not established (no filing pulled for this note) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No — nothing to provision; the one gate is the ship-lock (activation) |
| Method | `ble_direct` (offline activation, primary) / `cloud_account` (stock app, alternative) |
| Advertised name | `PEACH2`, `PEACH 2`, `PEACH™ 2`, `PEACH2GO`, `PEACH2ProMAX` |
| Passphrase protection | not_applicable (no Wi-Fi, no bond) |
| Confidence | medium (decompiled app, corroborated by the vendor manual; not replayed) |

**Offline activation** (the primary route — no account, no network):

1. Scan for a `PEACH…` advertisement, connect (no bonding), discover services.
2. **Security access** — write `01 A1 <MAC[3]> <MAC[4]> <MAC[5]>` (the last
   three bytes of the device's own BLE MAC) to characteristic `0A10`. Required
   after *every* connect before the device answers commands; the stock app
   retries up to 3 times.
3. Read the SW revision (`2A28`) — the device is ready, and the value selects
   the command dialect (below).
4. **Activation** (only a locked/factory unit needs the write): read `0A20`;
   if the first byte is `00`, write `01 02 <8-byte chipId>`. Then read `0A30`;
   unless it starts with `01`, write `01` (wake-up enabled). The whole thing
   is idempotent — the stock app re-runs it on every connect.

### chipId derivation

`chipId` is a fixed, keyless permutation of the 6-byte BLE MAC
(`m0 m1 m2 m3 m4 m5` in the usual printed order). With
`b = [m5, m4, m3, 0x00, 0x00, m2, m1, m0]`, all arithmetic mod 256:

```
out[0] = (b[2] & 0x0F) | (b[7] & 0xF0)
out[1] = (b[5] & 0x0F) | (b[1] & 0xF0)
out[2] = (b[7] & 0x0F) + (0xF0 - (b[6] & 0xF0))
out[3] = 0xFF - b[6]
out[4] = b[5] + 1
out[5] = (b[1] & 0x0F) + (0xF0 - (b[2] & 0xF0))
out[6] = (b[0] & 0x0F) | (b[5] & 0xF0)
out[7] = (b[6] & 0x0F) | (b[0] & 0xF0)
```

No key, no nonce, no server input — pure MAC arithmetic. Test vector for the
documentation MAC `AA:BB:CC:DD:EE:FF`: security-access write
`01 A1 DD EE FF`; chipId `AD EC 4A 44 CD 2E CF FB`; full activation write
`01 02 AD EC 4A 44 CD 2E CF FB`.

**Factory reset**: not established. No reset procedure was found in the app or
the manual text examined, and none is needed for normal ownership: activation
is idempotent, so a second-hand unit is adopted by just connecting and
activating it again. Don't improvise button sequences on an IPL device.

**Rebinding**: there is nothing to rebind — no network, no bond. A new phone
scans, connects, runs the handshake above, and drives the device.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | **No** — open GATT on a bare connection |
| Security mode | `app_layer` (no link-layer pairing; the "security" is the per-connection 0A10 handshake and the 0A20 activation, both derived from the public MAC) |
| Bonding | `none` — the app never bonds, the device stores no bond |
| PIN source | n/a |
| One central at a time | Unknown (likely for the chipset, not established) |
| One bond at a time | n/a (no bonds) |
| Confidence | medium (consistent through the app's BLE layer; not replayed) |

**Entering pairing mode**: not applicable — the device advertises whenever
powered. Whether a factory-locked unit advertises identically is unverified
(the app finds locked units, so presumably yes).

**Unpairing**: not applicable — no bond exists, so there is nothing to drop.
Moving to a new client needs no reset and no forget-device step.

## Protocol Summary

### BLE Services

Custom 16-bit UUIDs on the standard `0000xxxx-0000-1000-8000-00805f9b34fb`
base. **The containing service UUIDs are not pinned on hardware** — the app
enumerates the GATT table and selects characteristics by UUID, and clients
must do the same (`FFF1` is hypothesized under service `FFF0`; the `0Axx`
block's service is unknown).

| UUID | Name | Description |
|------|------|-------------|
| `0xFFF1` | Command channel | All commands written here; answers read back from the same characteristic |
| `0x0A10` | Security access | Per-connect handshake: `01 A1 <MAC[3..5]>` |
| `0x0A20` | Activate | Read: first byte `00` = locked. Write `01 02 <chipId>` to unlock |
| `0x0A30` | Wake-up | Write `01` to enable |
| `0x0A05` | Serial number | Read |
| `0x0A07` | Chip ID | Read (device-reported; distinct from the MAC-derived chipId) |
| `0x0A0C` | Skin-sensor polling | Read, calibration |
| `0x0A08` | OTA trigger | Reboots into OTA mode (TI OAD service `f000ffc0-…`) |
| `0x2A28` | SW revision | Read at every connect; selects the command dialect |
| `0x2A19` | Battery level | Read + notify (mains device; still exposed) |
| `0x2A24/2A26` | Standard DIS | Model / firmware revision |

### Commands

No framing: raw `opcode || payload`. First byte `0A` = set, `0B` = query;
queries are answered by **reading `FFF1` back** after the write. A read-back
starting with `FF FF FF FF` means busy — retry (the app allows 5).

| Command (hex) | Meaning |
|---|---|
| `0A01 <level>` | Set IPL intensity, 0–5 |
| `0B01` | Read intensity (first byte of read-back) |
| `0AD0 01` / `0AD0 06` | Removal mode Basic / **Pro** (new firmware; Pro is the paywalled one — firmware accepts it unconditionally) |
| `0BD0` | Read removal mode (value ≥ 6 ⇒ Pro) |
| `0AA2 0202020202` / `…0303030303` / `…0101010101` | Flash mode Basic / Pro / Face (old firmware; mode byte ×5) |
| `0BA2` | Read flash mode |
| `0AC4 <val>` / `0AC0 <val>` | Set cooling/fan (new / old firmware; `0AC0 0A` = auto-fan) |
| `0BC0` / `0BC4 0007` | Read cooling (old / new) |
| `0AB2`/`0BB2` | Temperature-enable set/read |
| `0AB4`/`0BB4`, `0AB5`/`0BB5` | Head / body NTC threshold set/read |
| `0AD1`/`0BD1` | Flash voltage table set/read |

**Dialect selection**: Peach 2 go / Pro MAX / Duo always use the new dialect.
A plain Peach 2 uses the old dialect when the last character of its SW
revision (`2A28`) is `a`–`c`, otherwise new.

## The paywall, plainly

The app has no in-app-purchase store integration; the subscription is
server-side, bought through an in-app web flow, fetched from the vendor API,
cached, and checked in the UI. When the device reports Pro mode and no
subscription is active, **the stock app writes Basic mode back to the
device** — that write is the entire enforcement mechanism. A replacement
client simply writes `0AD0 06` and nothing on the device checks anything.
(The mode switch is shown in the app for Peach 2 go / Pro MAX always and for a
plain Peach 2 on new firmware — SW revision not ending in `a`–`g`; it is
hidden on Peach 2 Duo. "Peach 2 Pro MAX" is a separate hardware SKU, not this
software mode.)

## Cloud Dependency

**Nothing to keep alive.** The device never touches the internet. The FOREO
cloud (`apiadmin.foreo.com`, `appadmin.foreo.com`, `www.foreo.com/api/…`)
serves the account, the product-registration bookkeeping, and the
subscription entitlement — all app-side. A total cloud shutdown leaves a
replacement client fully functional, including first-time activation of a
factory-fresh unit.

## Tools Used

- [x] jadx (decompile of FOREO For You 4.4.1 / 559)
- [x] apkeep (APK acquisition)
- [ ] BLE hardware — still needed for the open questions below

## Open Questions (need hardware)

- Containing GATT service UUIDs (`FFF0` hypothesis for `FFF1`; the `0Axx`
  block's service unknown) — one service discovery settles it.
- Does a factory-locked unit advertise identically and answer the
  security-access write / `0A20` read immediately?
- Read-back layouts for `0BD0`/`0BC4`, `0BA2`, `0BB2`/`0BB4`/`0BB5`, `0BD1`;
  the value map for the `0AC4` cooling write; payloads of the `0AB2`/`0AB4`/
  `0AB5`/`0AD1` set opcodes.
- Dialect edge cases: SW-revision suffixes beyond `a`–`c` on a plain Peach 2.
- OTA: the `0A08` trigger payload and whether the current app can OTA a Peach
  at all.
- FOREO Bear 2 (microcurrent, same app) appears to share the activation +
  subscription pattern — follow-up target.

## References

- [FOREO PEACH 2 full user manual](https://www.foreo.com/manuals/peach-2) — vendor-hosted; corroborates ship-lock and registration
- [FOREO For You on Google Play](https://play.google.com/store/apps/details?id=com.foreo.foreoapp) — the analysed companion app (store shows current release)
- Analysis APK: `com.foreo.foreoapp` 4.4.1 (versionCode 559), sha256 `90a4ec8f5c22c1085d1500f6bf1954c28edcd81531f0eed94bf8a13aa494ae79`

## Contributors

- Liberated Bread RE workspace — APK acquisition, decompile, protocol recovery
