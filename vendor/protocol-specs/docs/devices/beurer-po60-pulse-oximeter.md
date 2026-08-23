# Beurer PO60 Pulse Oximeter

> **Status**: In Progress (protocol fully mapped from two decompiled apps; not yet replayed against hardware by this project)
> **Protocol**: BLE (custom GATT service — *not* the standard PLX profile)
> **Manufacturer**: Beurer GmbH (Ulm, Germany)
> **Manufacturer Status**: Active (no cloud dependency at all — the device is phone-to-device over BLE only)

## Overview

The Beurer PO60 is a Bluetooth Smart (BLE 4.0) fingertip pulse oximeter. It
measures SpO2 and pulse rate, keeps up to 100 measurement sessions on-device,
and syncs them to a phone over a small custom GATT protocol. It is one of the
easiest devices in this knowledge base to liberate: **there is no cloud in the
loop at all** — the only radio is BLE, the companion apps work in guest mode,
and the entire sync protocol is three commands.

The protocol was recovered from two companion apps and cross-verified between
them: the legacy *beurer HealthManager* (`com.beurer.connect.healthmanager`
v2.17, unobfuscated) and the current *beurer HealthManager Pro*
(`com.beurer.healthmanager` v1.17.1, obfuscated Kotlin). A third-party,
hardware-tested Python (bleak) script —
[Shreyan1/Beurer-PO60-PulseOximeter-Bluetooth-Integration](https://github.com/Shreyan1/Beurer-PO60-PulseOximeter-Bluetooth-Integration) —
independently uses the same UUIDs and command bytes, and is a working
reference client.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Beurer PO60 |
| Chipset | Unknown — firmware is built on the "ilink" BLE SDK (`com.ilink.bleapi`) shared across the Beurer/Sanitas medical line, pointing at Beurer's usual Chinese ODM |
| Radio | BLE 4.0 (Bluetooth Smart) only — no Wi-Fi, no other radio |
| FCC ID | **Not found** — the US manual carries only a generic Part 15 statement; needs a label photo / fccid.io visual search |

Color OLED display; stores up to 100 measurement sessions. No firmware-update
path exists in either app, and no firmware image is public.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No — nothing to provision (no network, no account) |
| Method | `ble_direct` (scan, connect, bond) |
| Setup AP / advertised name | Advertises with the exact local name `PO60` |
| Passphrase protection | not_applicable (no Wi-Fi); BLE bonding uses a 6-digit passkey printed in the device manual |
| Confidence | medium (read from both decompiled apps; not replayed here) |

The flow, as both apps drive it:

1. Scan for the exact name `PO60`, connect.
2. Complete BLE passkey bonding (the 6-digit PIN from the manual).
3. Enable notifications on the FF02 characteristic.
4. Set the clock (command `0x83`) — both apps do this immediately after
   bonding; the device acks with `F3 00`.
5. Query the stored-record count (`90 05 15`), then page the history log
   (see below).

Open bonding questions (need hardware): whether some firmware revisions accept
Just-Works instead of the passkey, and whether an *unbonded* client can
already write the time-set command — that decides whether third-party clients
need the PIN at all.

**Factory reset**: not established. No reset procedure exists in either app or
in the US manual text examined; the device holds measurement history plus BLE
bonding state. Don't guess one — if you need to move the device to a new
phone, remove the old bond in the previous phone's OS Bluetooth settings and
re-pair; measurement history survives.

**Rebinding**: in place, no reset needed — ordinary BLE re-bonding.

## Protocol Summary

### BLE Services

All UUIDs are 16-bit aliases on the standard `0000xxxx-0000-1000-8000-00805f9b34fb`
base.

| UUID | Name | Description |
|------|------|-------------|
| `0xFF12` | Pulse Oximeter service | The only application service |
| `0xFF01` | Command | Client writes all commands here |
| `0xFF02` | Response / data | Acks and measurement data, as notifications |

The device does **not** implement the standard BLE Pulse Oximeter profile
(0x1822 PLX) — per both apps; confirm on-air before relying on it. No
encryption anywhere: plain bonding is the only protection, and all numeric
fields are 7-bit-masked integers.

### Commands

#### Command: Read storage info

**Request** (write to FF01): `90 05 15`

**Response** (notify on FF02): carries the number of stored measurement
records. Exact length/offset of the count byte is **not yet pinned down**
(open question).

#### Command: Set date/time

**Request** (write to FF01):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Command ID `0x83` |
| 1 | 1 | Year − 2000 |
| 2 | 1 | Month |
| 3 | 1 | Day |
| 4 | 1 | Hour |
| 5 | 1 | Minute |
| 6 | 1 | Second |
| 7–8 | 2 | `00 00` pad |
| 9 | 1 | Checksum: (sum of bytes 0–8) & 0x7F |

**Response**: ack `F3 00` on FF02. (The legacy app wrote placeholder
`05 05 05` in the seconds/pad positions; the Pro app sends real seconds —
send real time.)

#### Command: Get measurements page

**Request** (write to FF01): `99 pp CKS` — `pp` = `0x00` START / `0x01` NEXT;
for this command the checksum is `(pp - 0x67) & 0x7F`, giving the observed
wire bytes `99 00 19` and `99 01 1A`.

**Response** (notify on FF02): measurement records stream as 20-byte
notification chunks; concatenate and slice into 24-byte records. The app
issues `99 01 1A` every 12 records (page size 12 inferred, not confirmed)
until the end-of-transfer record arrives, then disconnects ~3 s later.

**Record layout** (24 bytes, after reassembly):

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Header `0xE9` |
| 1 | 1 | Low nibble = record index; **high nibble `0x4` = end-of-transfer** |
| 2–7 | 6 | Start time: year−2000, month, day, hour, minute, second |
| 8–13 | 6 | End time, same layout |
| 14 | 1 | Pulse-rate escape flags: bit 2 → +128 to PR max, bit 3 → PR min, bit 4 → PR avg |
| 15–16 | 2 | Unknown |
| 17 | 1 | SpO2 max (%) |
| 18 | 1 | SpO2 min (%) |
| 19 | 1 | SpO2 avg (%) |
| 20 | 1 | PR max (bpm) |
| 21 | 1 | PR min (bpm) |
| 22 | 1 | PR avg (bpm) |
| 23 | 1 | Unknown |

All value fields are plain 7-bit integers; pulse-rate values ≥ 128 escape via
the flag byte at offset 14.

## Cloud Dependency & Home Assistant Guidance

**There is nothing to keep alive.** The PO60 never touches the internet: no
Wi-Fi, no cloud, no account. Beurer's HealthManager clouds
(`sync.connect-beurer.com`, `hmpro[-us].connect.beurer.com`, SSO hosts) exist
only as optional sync storage inside the phone apps, both of which also run in
guest mode — and Beurer is a healthy, actively-maintained vendor anyway. Any
cloud shutdown, today or in ten years, changes nothing for this device.

For Home Assistant: no HA/ESPHome integration exists yet, and none is needed
beyond a small bleak script (or an ESPHome Bluetooth proxy driving one) that
runs the five-step sync flow above on a schedule. The Shreyan1 repository is a
working starting point. Note the interaction model is **history sync** — the
protocol pulls stored sessions after the fact; no command to stream a live,
in-progress measurement was found in either app, and whether the hardware
supports that is unknown.

## Tools Used

- [x] jadx (decompiles of HealthManager 2.17 and HealthManager Pro 1.17.1)
- [x] apk.cafe / filesincloud.com CDN (APK acquisition)
- [ ] BLE sniffer / hardware unit — still needed for the open questions below

## Open Questions (need hardware)

- Does the PO60 also expose standard PLX (0x1822) or a battery service
  alongside FF12? (Decompile says no; confirm on-air.)
- Exact format of the storage-info response to `90 05 15`, and the real page
  size of the `99` command (12 records/page is inferred).
- Bonding: fixed per-device passkey, or Just-Works on some firmware
  revisions? Can an unbonded client write time-set?
- FCC ID from the device label.
- Record bytes 15, 16 and 23.

## References

- [Shreyan1/Beurer-PO60-PulseOximeter-Bluetooth-Integration](https://github.com/Shreyan1/Beurer-PO60-PulseOximeter-Bluetooth-Integration) — hardware-tested bleak reference client
- [beurer HealthManager Pro on Google Play](https://play.google.com/store/apps/details?id=com.beurer.healthmanager) — the maintained vendor app
- [openScale](https://github.com/oliexdev/openScale) — open-source sibling Beurer/Sanitas BLE protocols (same ilink SDK family)
- [Bluetooth SIG Pulse Oximeter service (0x1822)](https://www.bluetooth.com/specifications/specs/pulse-oximeter-service-1-0/) — the standard profile the PO60 notably does *not* implement
- Analysis APKs: `com.beurer.healthmanager` v1.17.1, sha256 `52f1810278f181bda7e89f8d78f6349e2b77af3295692129610e7210873c0e30`; `com.beurer.connect.healthmanager` v2.17, sha256 `ea3ec53ef9f9a6bc2eaf56237d7383af90f4e99b778036b4a2034d0ea4468a51`

## Contributors

- Liberated Bread RE workspace — APK acquisition, decompile, cross-verification
