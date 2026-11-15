# Exway Electric Skateboards (X1 / Flex / Wave / Atlas)

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Exway
> **Manufacturer Status**: Active (this generation's app, "Exway", is superseded by ExSkate for newer hardware)

## Overview

Exway's second-generation electric skateboards are the X1 Pro, X1 Max,
X1 Skate, Flex, Flex SE, Flex (2022), Wave and Atlas. They talk to a phone over
BLE. The phone connects straight to the board's **receiver**, the radio module
that also links the handheld R1/R2 remote and passes messages on to the board's
one or two ESCs. The vendor app for this generation is **Exway**
(`com.exway.app`).

Exway's third generation (R3 remote, ESC 3.0) works differently. Its ExSkate
app pairs the phone with the R3 remote rather than the board, and Exway's own
ExSkate guide tells R1/R2 owners to keep using the older Exway app. This page
covers the second generation only.

Everything here was read out of the vendor's Android app (version 1.8.1) and
checked against Exway's manuals. Nobody on this project has connected to a
board. There is no capture, no FCC filing and no screenshot of the app in the
research store, so every byte fact is **reported**, not confirmed.

**In scope:** identifying the board and its model, live telemetry, battery
pages, reading the settings memory, saving, and a small set of settings the
vendor app itself offers.

**Out of scope, on purpose:**

- the handheld remote's own radio link to the board
- firmware and bootloader updates for the receiver, the remote and the ESCs
- writes to the per-gear speed limits, acceleration and brake curves and
  currents, turbo, wheel size, gearing, the power-system type and the mileage
  counters

!!! warning "This is a vehicle, and the link has no authentication"
    Settings written over this link change how a moving skateboard shifts,
    cruises and brakes. Change them only with the board stopped and nobody on
    it. The vendor app will not open its board-settings page unless the board
    reports less than 2 km/h. Anything within radio range of a powered board
    can do what the app does. Wheel size and gearing feed the speed the board
    calculates, and the mileage counters gate the new-rider gear limit, which
    is why this spec does not document writing them.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | X1 Pro, X1 Max, X1 Skate, Flex, Flex SE, Flex (2022), Wave, Atlas (told apart by a model string the board reports; see [Identification](#identification)) |
| Chipset | Not identified. The receiver sits behind a BLE module with its own AT-command configuration port (`OK+...` answers) |
| Radio | BLE to the phone. A separate radio link to the handheld remote, not covered here |
| Drive | Hub motors or Exway's "Riot" belt drive, one or two ESCs (Atlas 4WD has two, each with its own power button) |
| FCC ID | Not found. fccid.co has no Exway grants under "Exway", "Exway Technology" or "electric skateboard" |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | Not established. The app lists every named BLE device and lets the user pick; the name can be changed through the module's AT port |
| Passphrase protection | not_applicable |
| Confidence | low (app-derived, not replayed) |

To connect:

1. Hold the board's power button for about three seconds. The status light
   turns solid green (Atlas Carbon manual).
2. Close the vendor app on any other phone.
3. Scan and connect. The board's primary service is
   `0000f1f0-0000-1000-8000-00805f9b34fb`. Whether it is advertised is not
   known, so be ready to fall back to picking the board from a list of named
   devices.
4. Subscribe to notifications on `0000f1f2-0000-1000-8000-00805f9b34fb`.
5. Write the heartbeat `b0 00 00 70` to `0000f1f1-0000-1000-8000-00805f9b34fb`.
   A 4-byte reply starting `b1` means the receiver is running normally.
6. Read the five information pages and check the model string.

**Factory reset**: not established. The manuals describe no reset of the
board's settings, and for a phone there is nothing to reset: the board keeps no
bond and no credential. The vendor app's "Restore default" item is not a
factory reset. It rewrites the stored mileage counter, which puts the board
back under the new-rider gear limit, so this spec leaves it out. Holding the
power button for eight seconds with the board off pairs the **handheld
remote**, not the phone.

**Rebinding to a new network**: not applicable. A new phone connects the same
way once the old one has disconnected.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | not applicable |
| One central at a time | Unknown |
| One bond at a time | not applicable |
| Confidence | medium (the vendor app never bonds or encrypts; not replayed) |

**Entering pairing mode**: not needed. The board accepts a connection whenever
it is on.

**Unpairing**: nothing to unpair.

**Recovery**: close the vendor app on every other phone, then power-cycle the
board if it still does not answer.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000f1f0-0000-1000-8000-00805f9b34fb` | Receiver data service | Request/reply channel to the board |
| `0000f1f1-0000-1000-8000-00805f9b34fb` | Request | Write requests here |
| `0000f1f2-0000-1000-8000-00805f9b34fb` | Reply | Every reply arrives here as a notification |
| `0000f2f0-0000-1000-8000-00805f9b34fb` | BLE module AT service | The module's configuration port (send `0000f2f1`, receive `0000f2f2`). Not a second ESC |

An earlier research note had the request and reply characteristics swapped.
The app's own set-up call writes to `f1f1` and listens on `f1f2`, and that is
what the spec follows.

The app also contains `0000fee9` with `d44bc439-abfd-45a2-b575-925416129600` /
`d44bc439-abfd-45a2-b575-925416129601`, and `0000fee8` with
`003784cf-f7e3-55b4-6c4c-9fd140100a16` / `013784cf-f7e3-55b4-6c4c-9fd140100a16`.
Those are defaults of the open-source BLE library the app is built on
([aicareles/Android-BLE](https://github.com/aicareles/Android-BLE)). The app
overrides them at start-up and never uses the library's OTA helper, so they say
nothing about Exway hardware.

### Framing

Every request is `[head][arguments][check]`. The check byte is the **low byte**
of CRC-16/MODBUS over everything before it (reflected polynomial `0xA001`, init
`0xFFFF`, no final xor). Only the low byte is sent. All multi-byte values are
big-endian. Replies end the same way.

| Shape | Bytes | Used for |
|---|---|---|
| Short request | `[head][arg high][arg low][check]` | heartbeat, monitor, battery, information pages, save, mode change |
| Parameter read | `[74][addr high][addr low][len high][len low][00][00][check]` | reading settings memory, 16 bytes at a time |
| Parameter write | `[75][addr high][addr low][value][check]` (1 byte) or `[75][addr high][addr low][value high][value low][check]` (2 bytes) | changing a setting |

Send one request at a time and wait for its reply. The app waits up to 500 ms
(1.5 s for a save). Replies can arrive split over notifications or run
together, so reassemble by head: `91`, `92` and `b4` replies are 20 bytes;
`74`/`75` replies are 4 bytes plus the data; `b1`, `b3` and `76` replies are
4 bytes.

### Commands

| Request (hex) | Reply | Purpose |
|---|---|---|
| `b0 00 00 70` | `b1 ...` (4 bytes) | Heartbeat. `11 ...` instead means the receiver is in its bootloader |
| `90 f0 0f 75` | `91 ...` (20 bytes) | Live telemetry (below) |
| `92 00 00 d0` / `92 00 01 11` | `92 ...` (20 bytes) | Battery page 0 (charge, voltage, temperature, cycles) / page 1 (battery firmware, capacities) |
| `b4 00 0n <check>` (n = 0-4) | `b4 00 0n` + 16 bytes + check | Receiver information, five pages |
| `74 00 90 00 10 00 00 ee` ... `74 00 d0 00 10 00 00 ef` | `74 00 addr` + 16 bytes + check | Settings memory 0x90-0xdf |
| `74 00 cc 00 04 00 00 7e` | `74 00 cc` + 4 bytes + check | Total mileage, 0.1 km units |
| `76 00 00 90` | `76 ...` (4 bytes) | Save settings to flash |
| `b2 70 00 f4` | `b3 70 status ..` | Return the receiver to its normal mode |

The information pages' check bytes are `31`, `f0`, `b0`, `71`, `30` for pages
0-4. The spec lists every request as a complete byte string, because the
schema has no way yet to fill in a truncated CRC.

**Information pages.** Concatenated, the five pages are 80 bytes holding five
16-byte UTF-8 strings: firmware version (e.g. `SE-01.01.10`), hardware version,
model string, bootloader version and a per-unit code. Don't publish the
per-unit code.

### Identification

The app tells the models apart by the model string on information page 2 and
compares it as a whole string:

| Model string | Notes |
|---|---|
| `exway X1 Pro` | Firmware at or below `SE-01.01.10` stores wheel size as a list index (80/83/85 mm) |
| `exway X1 Max` | |
| `exway X1 Skate` | Wheel size as a list index; the app hides the gearing item |
| `exway Flex` | Also a prefix of the next two, so compare exactly |
| `exway Flex SE` | |
| `exway Flex(2022)` | No space before the parenthesis |
| `exway Wave` | The only model the app shows its lighting page for; cruise control hidden |
| `exway Atlas` | |

### Live telemetry (reply `91`)

| Offset | Length | Field | Decoding |
|---|---|---|---|
| 0 | 1 | head | `0x91` |
| 1 | 2 | speed | uint16 BE × 0.001 km/h |
| 3 | 2 | output | int16 BE; the app divides by 32 and shows it as "power output". Unit not established |
| 5 | 2 | ESC temperature | 12-bit ADC count; see below |
| 7 | 2 | motor temperature | 12-bit ADC count; see below |
| 9 | 2 | trip | uint16 BE × 0.1 km |
| 11 | 2 | (unlabelled) | uint16 BE; the app scales it by 0.1 and never shows it |
| 13 | 2 | battery voltage | uint16 BE × 0.001 V |
| 15 | 1 | battery | bits 0-6: percent; bit 7: charging |
| 16 | 2 | battery temperature | int16 BE × 0.1 °C (shown only when byte 18 is 1 or more) |
| 18 | 1 | pack code | 0, 1 or 2; the app assumes a 26, 22 or 32 km full-charge range |
| 19 | 1 | check | CRC-16/MODBUS low byte of bytes 0-18 |

Worked example (synthetic): `91 48 44 01 40 08 00 08 00 00 7b 00 00 9b 78 4b 00
f5 01 42` is 18.5 km/h, output 10, ESC 63 °C, motor 23 °C, trip 12.3 km,
39.8 V, 75 % and not charging, battery 24.5 °C, pack code 1.

**Temperatures.** The ESC and motor readings are ADC counts. The app works out
a thermistor resistance, `R = raw × 10000 / (4095 − raw)` ohms, and looks it up
in a per-degree table from −11 °C to 199 °C, reporting the lower degree of the
step. A beta-model curve with B ≈ 3877 K, referenced to 24 °C at 47.0 kΩ (ESC)
or 10.0 kΩ (motor), reproduces the app within about 1 °C. For example, ESC raw
2048 reads 63 °C and motor raw 1000 reads 52 °C. When nothing matches, the app
reports −11 and shows "−".

### Settings memory

The settings memory is 256 bytes. The spec's `protocol_details.parameter_memory`
maps all of it. The addresses the declared commands touch:

| Address | Setting | Values | In this spec |
|---|---|---|---|
| 0x94 (148) | Safe mode | 1 = on | Advanced |
| 0x95 (149) | Safe mode's highest gear | 1-4 | Advanced |
| 0x96 (150) | Gear change while moving | 1 = allowed | Advanced |
| 0x97 (151) | Free mode (wheels spin backwards on reverse throttle) | 1 = on | Advanced |
| 0x98 (152) | Cruise control | 1 = available | Advanced |
| 0xc2 (194) | Standby timer | 1 = on | Yes |
| 0xc3 (195) | Standby time | hours: 2, 24, 48, 168 | Yes |
| 0xd0 (208) | Light animation | 0 throttle, 1 comet, 2 breath, 3 colour breath, 4 steady, 5 none | Yes |
| 0xd5 (213) | Brake light | 1 = on | Yes |
| 0xd7 (215) | Tail light | 1 = on | Yes |

Ride settings go through a write and then the save request (`76 00 00 90`), as
the app does. The app writes light settings without a save so they preview
live. Reading addresses 0x9a-0xc1 shows the per-gear speed limits, curves and
currents, which the spec documents for reading only.

**New-rider limit.** The app's quick guide says a new board allows only gears 1
and 2 until it has covered 10 km. The app treats a mileage counter below 10 km
as that state and warns that settings changes are void until then.

### Firmware updates

The app updates the receiver, the remote and the ESCs over this same link,
using images it looks up from Exway's API (`api.exwayboard.com`). The routine
that enters the update path did not decompile to source, and the flashing bytes
are left out on purpose. A receiver left in its bootloader answers the
heartbeat with `11` instead of `b1`, and the vendor app then goes straight to
its firmware page.

## Troubleshooting

- **Nothing answers the heartbeat.** The vendor app on another phone is
  probably still connected. Also check that you write to `f1f1` and listen on
  `f1f2`; an earlier write-up had them the other way round.
- **The heartbeat reply starts `11`.** The receiver is in its bootloader,
  usually after an interrupted firmware update. Only the vendor app's firmware
  page recovers it; this spec does not document that path.
- **A saved setting reads back unchanged.** The board has covered less than
  10 km, or it was moving. The app only offers settings below 2 km/h.
- **The app's settings screen shows a value you did not set.** As decompiled,
  after a write retry the app can file the echoed data at the wrong offset in
  its cached copy of the settings. Re-read the page after writing.
- **A session starts with the mode unknown.** The app's mode lookup returns
  before its own query finishes. Wait for the heartbeat reply before sending
  anything else.

## Tools Used

- [x] jadx over the vendor app (Exway 1.8.1), including a second pass that
  prints best-effort code for routines that failed to decompile
- [x] Exway's manuals (Atlas Carbon, X1 Riot, Flex 2022/ER, Wave) and the
  ExSkate app guide
- [x] fccid.co search (no Exway grants)
- [ ] nRF Connect or an HCI snoop log against a real board: **still needed**

## References

- [Exway Atlas Carbon 2WD/4WD manual (PDF)](https://cdn.shopify.com/s/files/1/0694/9083/5704/files/Atlas_Instruction_Manual_-_China_UK_France_Korea_Japan_Germany.pdf?v=1766390343)
- [Exway X1 Riot manual (PDF)](https://cdn.shopify.com/s/files/1/0576/4890/6294/files/Instruction_Manual_-Exway_X1_Riot_Instruction_Manual_-_English_312de417-c979-426a-9c15-a1e28b9e2098.pdf?v=1702869744)
- [Exway Flex Hub/Belt (2022) and Flex ER manual (PDF)](https://cdn.shopify.com/s/files/1/0576/4890/6294/files/Flex_2023_Instruction_Manual_-_China_UK_France_Korea_Japan_Germany_380d7747-0f07-4ba0-aa0a-ec740f5b2c78.pdf?v=1702869750)
- [Exway Wave (first generation) manual (PDF)](https://cdn.shopify.com/s/files/1/0576/4890/6294/files/Wave_Instruction_Manual_-_English_8acc1c3b-f804-4054-ad91-bab8a3e2cf4f.pdf?v=1702869745)
- [ExSkate app user guide (PDF)](https://cdn.shopify.com/s/files/1/0576/4890/6294/files/ExSkate_APP_Instruction_Manual_-_English_af53201e-57e7-4c90-8b12-b674350a1060.pdf?v=1702869747)
- [aicareles/Android-BLE (the app's BLE library)](https://github.com/aicareles/Android-BLE)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- Machine-readable spec: `device-specs/devices/exway-eskate.yaml`

## Contributors

- Claude Code agent: spec written from the vendor app and manuals (desk research; no hardware)
