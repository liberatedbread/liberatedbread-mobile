# Beurer PO60 Pulse Oximeter

> **Status**: Capture verified (existing Android HCI capture; not driven end to end by this project)
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

!!! warning "Medical device"
    SpO2 and pulse values synced through this spec are a personal log, not a
    clinical measurement, and must never decide whether someone needs oxygen,
    a medication or urgent care. Chart them if you like; act on the device's
    own display and a professional's advice. The spec carries a
    `safety_advisory` saying so.

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
| Aliases | PO60, PO 60 |
| Category / hierarchy | `health` + `["measurement", "health", "pulse_oximetry"]` |
| Manufacturer | Beurer GmbH |
| Companion app | Current: beurer HealthManager Pro (`com.beurer.healthmanager`); older manuals name regional/historical apps |
| Chipset | Unknown — firmware uses the "ilink" BLE SDK family shared across the Beurer/Sanitas medical line |
| Radio | BLE 4.0 (Bluetooth Smart) only — no Wi-Fi, no other radio |
| FCC ID | **Not found** — the US manual carries only a generic Part 15 statement; needs a label photo / fccid.io visual search |

Color OLED display; stores up to 100 measurement sessions. No firmware-update
path exists in either app, and no firmware image is public.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No — nothing to provision (no network, no account) |
| Method | `ble_direct` (connect during `SYNC`, bond, download history) |
| Setup AP / advertised name | Advertises with the exact local name `PO60` |
| Passphrase protection | not_applicable (no Wi-Fi); BLE bonding uses a random six-digit PIN shown on the PO60 display |
| Confidence | medium (vendor workflow and SMP bonding confirmed; complete client flow not replayed here) |

Enable Bluetooth on both devices and open a compatible app, or have a
third-party client ready to connect. After a measurement, **remove your
finger**: the PO60 enters `SYNC` and tries to connect for approximately ten
seconds. To transfer stored measurements later, hold the function button for
five seconds while the PO60 is switched off until `SYNC` appears. The
device's Bluetooth setting must be `ON` for either route.

1. Scan for the exact name `PO60` and connect during the `SYNC` window.
2. On first pairing, enter the random six-digit PIN shown on the **PO60
   display**, not a fixed PIN from the manual. Reuse a valid existing bond
   on later transfers.
3. Enable notifications on the FF02 characteristic.
4. Set the clock (command `0x83`); the device acks with `F3 00`.
5. Query the stored-record count (`90 05 15`), then page the history log
   (see below) through its end marker. The PO60 transfers all stored
   measurements and switches off automatically.

Do not hold an idle connection expecting live SpO2 notifications. How reliably
a third-party central can reuse the bond, and whether an unbonded client can
write the time-set command, remain open.

**Factory reset / memory clearing**: no owner-accessible procedure to clear
the stored measurements is documented, and no reset procedure was found in
either app or the examined manuals. The device holds measurement history plus
BLE bonding state. Don't guess one — to move the device to a new phone,
remove the old bond in the previous phone's OS Bluetooth settings and re-pair
using the newly displayed PIN; measurement history survives.

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

Full GATT discovery in the reviewed capture found no standard BLE Pulse
Oximeter profile (0x1822 PLX), agreeing with both apps. No application-layer
encryption was found: BLE bonding is the only protection, and all numeric
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

For Home Assistant: no HA/ESPHome integration exists yet. A small bleak
script (or an ESPHome Bluetooth proxy driving one) can use the Shreyan1
repository as a starting point, but should connect during the device-initiated
`SYNC` window rather than polling for continuous samples. The reviewed capture
shows a clock write and a bounded history transfer, not live measurements;
the record parser still needs validation against annotated real readings.

## Tools Used

- [x] App static analysis (HealthManager 2.17 and HealthManager Pro 1.17.1)
- [x] Vendor manuals and PLUX PO60 workflow guide
- [x] Existing Android HCI capture, reviewed 2026-11-07: SMP/MITM bonding,
  full GATT discovery, `0x83` clock write, `99 00 19` history start and
  20/20/8-byte notification chunks; no PLX service or live stream observed
- [ ] Annotated hardware run for record parsing and the open questions below

The capture contains no physical finger-state signal, so the finger-removal
trigger comes from the vendor/PLUX workflow, not from the capture.

## Open Questions (need hardware)

- Does the PO60 expose a battery service alongside FF12? Full GATT discovery
  in the reviewed capture found no PLX service, agreeing with the app analysis.
- Exact format of the storage-info response to `90 05 15`, and the real page
  size of the `99` command (12 records/page is inferred).
- How reliably can a third-party central reuse the bond? Can an unbonded
  client write time-set?
- Behavior of other firmware/app versions, including any live-streaming path.
- FCC ID from the device label.
- Record bytes 15, 16 and 23.

## References

- [Official Beurer PO60 instructions (2020 international edition)](https://pim.beurer.com/images/attribut/454.20-PO60_2020-04-24_04_IM1a_BEU_DE-EN.pdf) — device-display random PIN, both transfer methods, approximately ten-second connection window and automatic shutdown
- [PLUX: Getting Started with the Beurer PO60](https://support.pluxbiosignals.com/knowledge-base/getting-started-beurer-pulse-oximeter-po-60/) — finger removal enters Sync Mode
- [Shreyan1/Beurer-PO60-PulseOximeter-Bluetooth-Integration](https://github.com/Shreyan1/Beurer-PO60-PulseOximeter-Bluetooth-Integration) — hardware-tested bleak reference client
- [beurer HealthManager Pro on Google Play](https://play.google.com/store/apps/details?id=com.beurer.healthmanager) — the maintained vendor app
- [openScale](https://github.com/oliexdev/openScale) — open-source sibling Beurer/Sanitas BLE protocols (same ilink SDK family)
- [Bluetooth SIG Pulse Oximeter service (0x1822)](https://www.bluetooth.com/specifications/specs/pulse-oximeter-service-1-0/) — the standard profile absent from the reviewed PO60 GATT discovery
- Analysis APKs: `com.beurer.healthmanager` v1.17.1, sha256 `52f1810278f181bda7e89f8d78f6349e2b77af3295692129610e7210873c0e30`; `com.beurer.connect.healthmanager` v2.17, sha256 `ea3ec53ef9f9a6bc2eaf56237d7383af90f4e99b778036b4a2034d0ea4468a51`

## Contributors

- Liberated Bread RE workspace — APK acquisition, decompile, cross-verification
