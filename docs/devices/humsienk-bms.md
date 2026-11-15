# HumsiENK Smart BMS (HS-prefixed LiFePO4 batteries)

> **Status**: Spec Available (from one community protocol document and its working ESP32 client; no capture, not run against hardware by this project)
> **Protocol**: BLE
> **Manufacturer**: HumsiENK (Shenzhen HumsiENK New Energy Technology Co., Ltd.)
> **Manufacturer Status**: Active (the "HumsiENK Smart BMS" app was updated in September 2026)

## Overview

HumsiENK sells 12 V, 24 V, 36 V and 48 V LiFePO4 batteries. The models
with "Smart" or "Mini Smart" in the name have Bluetooth. Their built-in
battery management system (BMS) advertises a BLE name starting `HS` and
answers a small binary request/response protocol over GATT. A client can
read voltage, current, state of charge and health, capacities, cycle
count, six temperatures, 24 cell-voltage slots and a 32-bit protection
and warning word. It can also switch the charge and discharge MOSFETs and
the heater, clear status, and recalibrate the current sensor. There is no
pairing, no password, no account and no cloud.

The machine-readable spec is
[`device-specs/devices/humsienk-bms.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/humsienk-bms.yaml).
Everything in it is `verification: reported`. The only description of the
protocol is the community project
[humsienk-esp32](https://github.com/mdelandgraaf/humsienk-esp32), an ESP32
bridge to Home Assistant. Its protocol document says it was
reverse-engineered from the vendor's Android app (1.2.0) and checked
against a real 4-cell pack. Its firmware is a working client. This page
restates the layouts in our own words. This project has not connected to a
pack.

**In scope:** packs whose BMS advertises `HS…` and serves service
`00000001-0000-1000-8000-00805f9b34fb`, the protocol the upstream write-up
calls "BMC".

**Out of scope:**

- **The "WATT" protocol.** The same vendor app has a second protocol for
  differently-branded packs, derived from the PACE/Pylontech BMS protocol,
  on service `0000fff0-0000-1000-8000-00805f9b34fb`. It was not
  researched. A pack showing `0000fff0` and no `00000001` service is not
  covered here.
- **Writing protection thresholds.** The threshold block (command `0x58`)
  is read-only here because no write command is documented. Guessing one on
  a battery's protection settings is not something to publish.
- **Firmware update.** None is documented.

!!! warning "This interface switches a battery's power path"
    Command `0x51` with data `00` cuts power to everything the battery
    feeds, such as an inverter, UPS, trolling motor or bilge pump. `0x50`
    with `00` stops charging, so a pack on solar can run flat. The
    current-calibration commands rescale how the BMS counts current. A
    wrong value corrupts the state of charge and the over-current
    accounting the protections rely on. The vendor app shows the FET
    controls as ordinary buttons, and owners running a UPS have asked for
    a way to lock them. The spec marks FET-off, forced heating, clear status
    and all three calibrations `advanced`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Bluetooth models: 12V 100Ah Smart, 12V 100Ah Max Smart, 12V 100Ah Max Plus Smart, 12V 314Ah Mini Smart, 12V 320Ah Smart, 12V 640Ah Smart; 24V 100 / 150 / 320 Smart; 36V 100Ah GC Smart, 48V 100Ah GC Smart / Ironguard Smart, 48V 150Ah GC Smart (from the vendor manuals). Which of them advertise `HS` and speak this protocol has not been checked model by model. Upstream tested one 4-cell (12 V) pack. |
| Chipset | Not established |
| Radio | BLE (always on while the pack is on; no Bluetooth button) |
| Advertised name | `HS<serial>`. The one published name is `HS` plus 16 upper-case hex digits, apparently a per-unit serial. |
| FCC ID | None printed in the manuals, and none found. The manuals list FCC among the pack certifications without an ID. |
| Vendor app | "HumsiENK Smart BMS": Android `uni.UNI3890CA7`, iOS App Store id6741700213 (1.2.5, 2026-09) |

The 12 V manual gives the BMS behaviour a client will see in the status
word. Charge is refused below 0 °C, discharge continues to −20 °C, and
discharge is cut at 70 °C. An over-current or short-circuit trip **stays
latched until the battery cables are removed**. The golf-cart packs list
discharge low-temperature protection down to −25 °C, so temperatures below
zero are normal readings on these packs.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `HS<serial>` (matched as `^HS[0-9A-F]{16}$`) |
| Passphrase protection | not_applicable |
| Confidence | high (working open implementation; not replayed here) |

There is nothing to provision. The pack has no Bluetooth button and
advertises whenever it is on. A client:

1. Scans for a local name matching `^HS[0-9A-F]{16}$`.
2. Connects without pairing and discovers services. It requires service
   `00000001-0000-1000-8000-00805f9b34fb` with write characteristic
   `00000002-0000-1000-8000-00805f9b34fb` and notify characteristic
   `00000003-0000-1000-8000-00805f9b34fb`, and disconnects otherwise.
3. Optionally requests an ATT MTU of 247, as the vendor app does.
4. Enables notifications on `00000003`.
5. Writes the handshake `AA 00 00 00 00` and waits for a checksum-valid
   frame echoing command `0x00`.
6. Polls battery info (`0x21`), cell voltages (`0x22`) and running status
   (`0x20`), one request at a time.

**`HS` is a weak prefix.** Two letters match plenty of unrelated devices,
so the spec matches the one published name shape, `HS` plus 16 upper-case
hex digits, rather than the bare prefix the open bridge uses; a pack named
any other way is missed until a second example widens it. The service UUID `00000001-…` is a 16-bit custom UUID that at least
one unrelated product also uses. Treat even a matching name as a candidate and confirm
with the GATT table plus a valid handshake echo. The spec does not use the
service UUID as a scan matcher. Whether it is advertised at all is not
established, and a scan filter on it would match any device advertising
16-bit service `0x0001`.

**Factory reset**: none is documented anywhere: not in the manuals, the
protocol document or the app listing. The BMS holds no pairing or network
state a client would need cleared. Command `0x53` "clear status" exists,
but what it clears is not documented, and nothing suggests it restores
defaults.

**Rebinding to a new network**: not applicable. There is no network
membership and no bond. A new phone or bridge connects as soon as no other
client holds the link.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | none |
| One central at a time | Unknown |
| One bond at a time | Not applicable (nothing bonds) |
| Confidence | medium (working open implementation, unreplayed) |

**Entering pairing mode**: not needed. The pack is always connectable
while on. Owners confirm there is no Bluetooth button.

**Unpairing**: nothing to unpair.

**Recovery**: if a client cannot connect, close the vendor app on every
nearby phone and stop any bridge polling the pack. Whether the BMS accepts
a second central is not established. The open bridge disconnects after
every poll sweep, which leaves the pack free either way.

The handshake has a fixed request and is not authentication. Anyone in
range can read the pack and switch its FETs.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00000001-0000-1000-8000-00805f9b34fb` | BMC service | 16-bit custom service `0x0001` on the SIG base |
| `00000002-0000-1000-8000-00805f9b34fb` | Command write | Request frames. The open client writes with response. |
| `00000003-0000-1000-8000-00805f9b34fb` | Response notify | Every response, possibly split across notifications |

### Frame

Requests and responses share one shape:

| Offset | Length | Field | Notes |
|--------|--------|-------|-------|
| 0 | 1 | start | always `0xAA` |
| 1 | 1 | command | the request's opcode. A response echoes it. |
| 2 | 1 | data length N | 0–255. A read request has N = 0. |
| 3 | N | data | parameters or response payload |
| 3+N | 2 | checksum | `(sum of bytes 1 … 2+N) & 0xFFFF`, **little-endian**. The `0xAA` is not summed. |

**Reassembly.** A response is `N + 5` bytes, and `N` is in the third byte
of the first notification. At the default MTU a battery-info response
(31 bytes) arrives in two notifications and a cell-voltage response (53
bytes) in three. Append notifications until `N + 5` bytes are held, then
check the checksum and the echoed command byte.

**Byte order.** Every multi-byte response field is little-endian. Upstream
notes that assuming big-endian produced garbage. The one exception is the
int16 reference current in commands `0x67` and `0x68`, which is
big-endian.

**One request in flight.** The vendor app queues its requests. Send the
next command only after the previous response arrived or timed out. The
open client allows 2.5 s.

### Commands

| Code | Name | Request data | Response | Notes |
|------|------|--------------|----------|-------|
| `0x00` | handshake | none | echo, data undocumented | once per connection, first |
| `0x10` | manufacturer name | none | ASCII | |
| `0x11` | pack name | none | ASCII | |
| `0x20` | running status | none | [running status](#running-status-0x20) | poll |
| `0x21` | battery info | none | [battery info](#battery-info-0x21) | poll |
| `0x22` | cell voltages | none | [cell voltages](#cell-voltages-0x22) | poll |
| `0x58` | protection parameters | none | int16 block, partial | read once |
| `0xF5` | firmware version | none | ASCII | read once |
| `0x50` | charge FET | `01` on / `00` off | echo on success | off is advanced |
| `0x51` | discharge FET | `01` on / `00` off | echo on success | off is advanced |
| `0x52` | heating | `01` on / `00` off | echo on success | on is advanced; only packs with a heater |
| `0x53` | clear status | none | echo on success | advanced: may release a latched protection |
| `0x66` | calibrate static current | none | echo on success | advanced |
| `0x67` | calibrate charge current | int16 **BE** mA | echo on success | advanced |
| `0x68` | calibrate discharge current | int16 **BE** mA | echo on success | advanced |

Ready-made frames (checksums computed):

| Command | Bytes |
|---------|-------|
| handshake | `AA 00 00 00 00` |
| battery info | `AA 21 00 21 00` |
| cell voltages | `AA 22 00 22 00` |
| running status | `AA 20 00 20 00` |
| firmware version | `AA F5 00 F5 00` |
| charge FET on / off | `AA 50 01 01 52 00` / `AA 50 01 00 51 00` |
| discharge FET on / off | `AA 51 01 01 53 00` / `AA 51 01 00 52 00` |
| heating on / off | `AA 52 01 01 54 00` / `AA 52 01 00 53 00` |
| charge calibration, 10.000 A | `AA 67 02 27 10 A0 00` |

The calibration checksum is a true 16-bit sum, so its high byte is not
always zero: 32.767 A is `AA 67 02 7F FF E7 01`, because
`0x67 + 0x02 + 0x7F + 0xFF = 0x01E7`. The spec's schema has no automatic
16-bit-sum field, so the two calibration commands declare their checksum
as a parameter the client must compute. The 16-bit field caps the calibration current at 32.767 A.
Which sign the app sends for a discharge reference is not documented.

### Battery info (0x21)

Offsets are into the data (add 3 for the frame offset). The data is 26
bytes on the tested pack.

| Offset | Length | Field | Type | Scaling |
|--------|--------|-------|------|---------|
| 0 | 4 | pack voltage | int32 LE | mV → ÷1000 = V |
| 4 | 4 | current | int32 LE, signed | mA → ÷1000 = A; **positive = charging** |
| 8 | 1 | state of charge | uint8 | % |
| 9 | 1 | state of health | uint8 | % |
| 10 | 4 | remaining capacity | int32 LE | mAh |
| 14 | 4 | full capacity | int32 LE | mAh |
| 18 | 2 | cycle count | uint16 LE | count |
| 20–23 | 1 each | temperatures 1–4 | int8 | °C, no offset |
| 24 | 1 | ambient temperature | int8 | °C, no offset |
| 25 | 1 | MOS temperature | int8 | °C, no offset |

The temperatures are whole degrees with **no offset**: no +40 and no
Kelvin, unlike several other BMS families. The upstream table calls them
unsigned. Its firmware reads them signed, and these packs operate well
below 0 °C, so the spec declares `int8`. A sub-zero reading has not been
observed on hardware. Which cell each probe sits on, and what an unfitted
probe reads, are not documented. The pack does not report power. Compute
voltage × current.

### Running status (0x20)

| Offset | Length | Field | Type |
|--------|--------|-------|------|
| 0 | 2 | uptime, days | uint16 LE |
| 2 | 1 | uptime, hours | uint8 |
| 3 | 1 | uptime, minutes | uint8 |
| 4 | 4 | status word | 32 bits, LE (read unsigned) |
| 8 | 4 | cell-balance flags | one bit per cell, order not documented |
| 12 | 3 | cell-disconnect flags | 24 bits for 24 slots, order not documented |

The status word names all 32 bits. A set bit means the condition is active
or the FET is on. This is the only place a client learns *why* a pack has
stopped charging or discharging.

| Bit | Mask | Meaning | Bit | Mask | Meaning |
|-----|------|---------|-----|------|---------|
| 0 | `0x00000001` | charge over-current protection | 16 | `0x00010000` | discharge over-current protection |
| 1 | `0x00000002` | charge over-temperature protection | 17 | `0x00020000` | discharge over-temperature protection |
| 2 | `0x00000004` | charge under-temperature protection | 18 | `0x00040000` | discharge under-temperature protection |
| 3 | `0x00000008` | cell over-voltage protection | 19 | `0x00080000` | cell under-voltage protection |
| 4 | `0x00000010` | pack over-voltage protection | 20 | `0x00100000` | short-circuit protection |
| 5 | `0x00000020` | AFE (measurement chip) error | 21 | `0x00200000` | pack under-voltage protection |
| 6 | `0x00000040` | charging stopped | 22 | `0x00400000` | discharging stopped |
| 7 | `0x00000080` | **charge FET on** | 23 | `0x00800000` | **discharge FET on** |
| 8 | `0x00000100` | charge over-current warning | 24 | `0x01000000` | discharge over-current warning |
| 9 | `0x00000200` | charge over-temperature warning | 25 | `0x02000000` | discharge over-temperature warning |
| 10 | `0x00000400` | charge under-temperature warning | 26 | `0x04000000` | discharge low-temperature warning |
| 11 | `0x00000800` | cell over-voltage warning | 27 | `0x08000000` | cell under-voltage warning |
| 12 | `0x00001000` | pack over-voltage warning | 28 | `0x10000000` | pack under-voltage warning |
| 13 | `0x00002000` | cell voltage-difference warning | 29 | `0x20000000` | MOS over-temperature warning |
| 14 | `0x00004000` | cell voltage difference too large | 30 | `0x40000000` | MOS over-temperature protection |
| 15 | `0x00008000` | heating | 31 | `0x80000000` | pre-discharge FET on |

The layout is symmetric: charge-side conditions sit in the low half-word
and discharge-side ones 16 bits higher. The upstream author fixed the bit
order by matching the app's bit tests against the field order of the app's
status model.

### Cell voltages (0x22)

Exactly 24 slots of uint16 LE millivolts (48 data bytes), with **no count
byte**. Slots for cells the pack does not have read 0. The number of
non-zero slots is the cell count, and min, max and spread are taken over
those only.

### Protection parameters (0x58)

A run of int16 values holding the protection thresholds, not mapped
upstream. Some temperature thresholds appear to be encoded as
`°C × 10 + 2731` (tenths of a kelvin). Field order, count and even byte
order are not documented. No write command is known, and the spec declares
none.

### Test vectors

Request frames above are the upstream worked examples, recomputed. These
response frames are **synthetic**, built from the layout with invented
values to test a decoder. None was captured.

| Frame | Decodes to |
|-------|-----------|
| `aa 21 1a f0 33 00 00 7e eb ff ff 57 64 d8 53 01 00 a0 86 01 00 0c 00 15 15 16 15 14 17 5f 08` | 13.296 V, −5.250 A, SOC 87 %, SOH 100 %, 87.0 / 100.0 Ah, 12 cycles, 21/21/22/21 °C, ambient 20 °C, MOS 23 °C |
| `aa 21 1a 30 33 00 00 00 00 00 00 28 64 40 9c 00 00 a0 86 01 00 03 00 fb fb fc fb fa fd 14 09` | 13.104 V, 0 A, SOC 40 %, probes −5/−5/−4/−5 °C, ambient −6 °C, MOS −3 °C |
| `aa 22 30 fd 0c fc 0c fe 0c f9 0c` + 40 × `00` + `72 04` | 3.325 / 3.324 / 3.326 / 3.321 V, 4 cells, 5 mV spread |
| `aa 20 0f 03 00 04 05 80 00 80 00 00 00 00 00 00 00 00 3b 01` | uptime 3 d 4 h 5 min, status `0x00800080` (both FETs on, no faults) |

## Troubleshooting

These come from Play Store reviews of the vendor app and from the 12 V
manual. The app-side ones do not affect a third-party client, but they
explain what owners run into.

- **The vendor app cannot find the battery (Android).** The app insists
  on the *precise* location permission and will not scan when location is
  set to "ask every time" (reported against 1.1.5–1.2.4). The pack needs no
  location. Also stay close: owners connect from about 1 m (1–3 ft).
- **The scan button opens a QR-code camera, or nothing happens.** Early
  app versions (1.0.17–1.1.1) opened a QR scanner from the scan button, and
  some failed on camera permission. One later version drew the Bluetooth
  connect control invisibly in a top corner. These are app defects. The
  BLE protocol has no QR or pairing step.
- **The app does not show cycle count or per-cell voltages.** Some app
  versions left them out. Both are in the protocol (`0x21` offset 18 and
  `0x22`), so a third-party client can show them.
- **A client connects and is dropped after a few seconds.** One report,
  app 1.1.9, new pack on charge. The cause is not established. Send the
  handshake promptly after subscribing, as the open client does, and make
  sure no other phone or bridge holds the pack.
- **The pack reads 0 V and does not answer.** A protection has cut the
  output. Per the 12 V manual, an over-current or short-circuit trip stays
  latched until the cables are removed. Disconnect the load, measure, and
  reconnect only above 10.8 V (12 V packs). When the BMS still answers, the
  status word (`0x20`) names the protection.

## Open questions

- The handshake response's data, and whether the BMS drops a client that
  skips the handshake.
- Whether the advertisement carries the service UUID or any manufacturer
  data.
- Whether more than one central can connect at once.
- The `0x58` block's layout and byte order, and how the app writes
  parameters (its store listing mentions parameter setting).
- The sign convention of the `0x67` / `0x68` reference current, and the
  preconditions the app enforces before calibrating.
- What `0x53` clear-status clears.
- The bit order of the balance and disconnect flags.
- Sub-zero temperature encoding on real hardware, and what an unfitted
  probe reads.
- Which models have a heater.
- Behaviour on 8S, 12S and 16S packs (only 4S tested upstream), and whether
  any "Smart" model uses the WATT protocol instead.
- A Play reviewer says a third-party app called KIJO reads and locks their
  HumsiENK pack. Which protocol that app speaks was not examined.

## Tools Used

- [x] Reading of the humsienk-esp32 protocol document and firmware (commit `fa0bb5a`)
- [x] Vendor manuals (12 V rev 2604, 24 V, golf-cart 2026, 12V 314Ah datasheet)
- [x] Vendor app store listings and reviews
- [ ] nRF Connect / btsnoop capture of a real pack (not done)

## References

- [HumsiENK 12V LiFePO4 Battery User Manual, rev 2604 (12 V range incl. Smart / Mini Smart models)](https://cdn.shopify.com/s/files/1/0867/1821/8558/files/Humsienk_12V_LiFePO4_Battery_User_Manual_2604.pdf?v=1776774089)
- [HumsiENK 24V LiFePO4 Battery User Manual (24V 100/150/320 Smart)](https://cdn.shopify.com/s/files/1/0867/1821/8558/files/Humsienk_24V_LiFePO4_Battery_User_Manual_Download.pdf?v=1772522277)
- [HumsiENK 36V / 48V golf-cart Bluetooth Battery User Manual (GC Smart models)](https://cdn.shopify.com/s/files/1/0867/1821/8558/files/Humsienk_36V_100Ah_Golf_Cart_Bluetooth_LiFePO4_Battery_User_Manual.pdf?v=1789381432)
- [HumsiENK 12V 314Ah Bluetooth battery, 200A BMS tech specs](https://cdn.shopify.com/s/files/1/0867/1821/8558/files/Humsienk_12V_314Ah_Bluetooth_LiFePO4_Battery_200A_BMS_Tech_Specs.pdf?v=1763973497)
- [humsienk-esp32: HumsiENK BMC BLE protocol (pinned)](https://github.com/mdelandgraaf/humsienk-esp32/blob/fa0bb5a17ed89061a919e7a80eb639cece12f671/docs/PROTOCOL.md)
- [humsienk-esp32 (ESP32 bridge, MIT)](https://github.com/mdelandgraaf/humsienk-esp32)
- [HumsiENK Smart BMS on Google Play](https://play.google.com/store/apps/details?id=uni.UNI3890CA7)
- [HumsiENK Smart BMS on the App Store](https://apps.apple.com/us/app/humsienk-smart-bms/id6741700213)
- [JBD / Xiaoxiang Smart BMS](jbd-xiaoxiang-bms-ble.md), another BLE BMS in this catalogue, for comparison
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Initial Device Setup](../protocols/device-setup.md)

## Contributors

- Claude Code agent: spec written from the humsienk-esp32 protocol document and firmware, the vendor manuals and the app store listings (no hardware, no capture)
