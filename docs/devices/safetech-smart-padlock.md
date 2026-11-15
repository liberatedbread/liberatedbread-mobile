# SafeTech Products Bluetooth Smart Padlock (Quicklock)

> **Status**: Research (full GATT map recovered from the app; no over-the-air capture yet)
> **Protocol**: BLE (normal roles — the lock is the peripheral)
> **Manufacturer**: SafeTech Products LLC (SDK by Itonsoft)
> **Manufacturer Status**: Shutdown (sites parked/offline ~2023, app removed from Google Play) — **but the device never used the cloud at all**

## Overview

The Quicklock is a zinc-alloy Bluetooth padlock sold from ~2015 by SafeTech
Products (marketed as the "world's first Bluetooth + RF/NFC padlock"; Li-Po
battery, USB charging). One embedded SDK and one companion app
(`com.itonsoft.safetech`, developer RPH Engineering) cover the whole family:
padlock, door lock, deadbolt and the Gunbox biometric safes, distinguished by
an ASCII type digit in the BLE scan record.

The vendor is gone and **it does not matter**: the protocol has no cloud, no
account, no pairing, no OTA. Pairing is phone↔lock only, and the lock works
indefinitely with any GATT client. The only real loss is the official app
(archived with this research: v2.0 / versionCode 26, sha256
`23eeaf15ea2d10135556ce1505cd8b70c7b5d82539449560033ab82e59036f9d`).

The trade-off for that simplicity is security: authentication is a static
4-byte password sent **in cleartext over an unencrypted, unbonded link**, and
unlocking is a single 0x01 write. Anyone in radio range can sniff the
password once and replay it forever. Rose & Ramsey demonstrated exactly this
against the Quicklock family in their DEF CON 24 smart-lock survey (2016).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Quicklock Padlock; family: DoorLock, Deadbolt, TheGunbox / Gunbox Echo / Gunbox SK-1 ("Big Bertha"); Medbox (marketing only) |
| Chipset | TI CC254x-class BLE SoC (inferred from leftover TI keyfob-demo UUIDs in the SDK; unconfirmed) |
| Radio | BLE 4.x (peripheral); RF/NFC tag reader on the padlock; Z-Wave module exists only on other family products |
| FCC ID | Not identified |

Device-type byte in the scan record (byte after a literal `0x2C` ','):
`'1'` padlock, `'2'` door lock, `'3'` deadbolt, `'4'`/`'5'` Gunbox safes.

## Initial Setup

There is nothing to provision — no network, no account, no BLE bonding.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` — scan, connect, write the password |
| Setup AP / advertised name | None; advertised name embeds the type string (`PadLock`, …) and the scan record carries `','` + ASCII type digit (parsing rule unverified against hardware) |
| Passphrase protection | not_applicable (no WiFi; the 4-byte lock password is cleartext on an unencrypted link) |
| Confidence | medium (flow read from the decompiled app; never run against hardware) |

Flow: scan and identify by the `0x2C` + type-digit pattern → connect and
discover services → enable notifications on `0xFFD7` → write
`[0x00][4-byte password]` to `0xFFD6` → verdict `[1]` (main OK) / `[1,1]`
(share OK) / `[0]` (wrong) → enable notifications on `0xFFDA`, sync the clock
(`0x1805/0x2A2B`, uint32 LE seconds since 2000-01-01 **local** time), read
battery and firmware revision → write `0x01` to `0xFFD9` to open.

Two things a first-time user must know:

- **The default password is unknown.** The vendor manual implies the user
  sets it at first pairing; whether a factory default (e.g. `00000000`) works
  out of the box needs hardware to confirm. If you buy one used, you need the
  current password — there is no documented recovery path without it.
- The "3 wrong passwords = lockout" timer is enforced **by the app only**;
  the lock-side behaviour is unknown.

**Factory reset**: unknown — no reset procedure was found in the decompiled
app or recovered vendor material. What exists instead is password rotation:
write `[0x01][new 4-byte password]` to `0xFFD6` (requires the current
password). RFID tags and fingerprints have their own delete commands
(`0xFFE3`; `0xFFC5` = delete-all on Gunbox biometric models — irreversible,
treat as advanced).

**Rebinding**: trivial. There is no network to rejoin; any controller that
knows the password connects and operates the lock. A "new phone" is just a
new GATT client.

## Protocol Summary

Normal BLE roles: the lock is the peripheral/GATT server, your client is the
central. No pairing, no bonding, no encryption, no MTU negotiation.

### BLE Services

| UUID (16-bit) | Name | Contents |
|------|------|-------------|
| `0xFFD0` | Lock main | password (`FFD6` write / `FFD7` notify), auto-relock time (`FFD8`), **lock control (`FFD9`: 0x01 open / 0x00 close)**, lock state (`FFDA`), LED time (`FFDB`), tamper alarm (`FFDC`) |
| `0xFFF0` | History | dump control (`FFF1`), 8-byte record frames (`FFF2`, end marker 8×`0xE0`), user name (`FFF3`, `[len][name]` ≤ 15 B) |
| `0xFFE0` | RFID / share | tag list dump (`FFE1`), delete tag (`FFE3`), add tag (`FFE4`, learn mode), share code (`FFE8`: code[4]+use-count), time-windowed code (`FFE9`, 17 B) |
| `0xFFC0` | Fingerprint / SureSet | Gunbox biometric models only (`FFC1`/`FFC2`/`FFC3` enroll / `FFC5` delete-all) |
| `0xFFB0` | Z-Wave module | status only (`FFB1`/`FFB2`); not on the padlock |
| `0x1805` | Current Time | clock sync: bare uint32 LE seconds since 2000-01-01 local time written to `0x2A2B` |
| `0x180A` | Device Information | model (`2A24`), firmware rev, 2 bytes (`2A26`), MAC (`2A23`) |
| `0x180F` | Battery | battery % (`2A19`) |

A generic UART service (`0xFF00`, TX `0xFF01` / RX `0xFF02`) is defined in
the SDK but unused by the lock flows — leftover boilerplate, not an
interface.

### Commands

There is no packet envelope: each characteristic is the message.

#### Command: Unlock / Lock

**Request** (write to `0xFFD9`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x01` = open/unlock, `0x00` = close/lock (only honoured after a successful password exchange) |

#### Command: Authenticate

**Request** (write to `0xFFD6`):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Sub-command: `0x00` = input/check, `0x01` = update password |
| 1 | 4 | Password (UI takes 8 hex chars; raw-hex vs ASCII encoding at firmware level is UNVERIFIED) |

**Response** (notify on `0xFFD7`): `[0]` wrong · `[1]` main password OK ·
`[1,1]` share password OK · codes 2/3 unknown.

#### Command: History dump

Write `0x01` to `0xFFF1`; 8-byte frames arrive on `0xFFF2`, terminated by
eight `0xE0` bytes. Record layout (type/ID/user/time) not yet decoded.

## Cloud Dependency & Home Assistant Notes

There is **no cloud dependency to plan around** — the vendor cloud never
existed in the protocol, and the company's 2023-ish disappearance broke
nothing. No keep-alive, no DNS redirect, no account migration is needed.

For Home Assistant users:

- No existing HA/ESPHome integration and no public RE repos were found for
  this family. The natural path is an ESPHome `bluetooth_proxy` plus a small
  script (or a `bleak`-based custom component) doing: write password to
  `0xFFD6`, then `0x01` → `0xFFD9`.
- The link is unencrypted and the password is static and sniffable. Treat it
  as public once used near anyone you don't trust, and don't reuse a
  password you care about.
- Firmware: none exists to archive (no OTA mechanism ever shipped). A
  failing lock cannot be revived by re-flashing; if firmware is ever needed
  it must be dumped from the TI CC254x-class SoC with a debugger.

## Tools Used

- [x] jadx (decompile of `com.itonsoft.safetech` v2.0, 1222 classes, no errors)
- [x] APKCombo download-flow replay (APK acquisition; APKPure purged, Play Store listing gone)
- [ ] BLE sniffer — one capture would settle every open question (the link is unencrypted, so any LE sniffer works)

## References

- [DEF CON 24 — Picking Bluetooth Low Energy Locks from a Quarter Mile Away (Rose & Ramsey, 2016)](https://defcon.org/html/defcon-24/dc-24-speakers.html) — Quicklock family among the locks tested; cleartext static-password weakness demonstrated
- [Wayback Machine — safetechproducts.com](https://web.archive.org/web/2022/https://safetechproducts.com/) (last real capture 2022-11; thequicklock.com / thegunbox.com likewise dead)
- [Bluetooth SIG assigned numbers](https://www.bluetooth.com/specifications/assigned-numbers/) — company ID `0x04CD` = Safetech Products LLC (advert usage unconfirmed)
- Verification APK: `com.itonsoft.safetech` v2.0 (vc26), sha256 `23eeaf15ea2d10135556ce1505cd8b70c7b5d82539449560033ab82e59036f9d`

## Contributors

- Liberated Bread RE workspace — APK acquisition, decompile and spec integration
