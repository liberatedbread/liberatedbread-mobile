# AC Infinity UIS Controller (BLE)

> **Status**: Spec Available (from two open implementations run on a Controller 69 Pro, plus upstream captures of the vendor app; not run against hardware by this project)
> **Protocol**: BLE
> **Manufacturer**: AC Infinity Inc.
> **Manufacturer Status**: Active

## Overview

AC Infinity's UIS controllers run grow-tent equipment such as inline fans,
lights, humidifiers and heaters from climate triggers, timers and
schedules. Each port has its own mode. The phone talks to the controller
directly over BLE GATT, with no bonding, no account and no cloud key. The
vendor app mirrors everything to AC Infinity's cloud, and none of that is
needed for local control.

Every command travels in an **A5 envelope** with a length, a sequence
number and two CRC-16/CCITT-FALSE checksums. The payload is a list of
`[selector][length][value]` items, followed by `ff <port>`. Two rules catch
out almost every first implementation:

- **A mode takes two writes.** A mode's parameters (thresholds, cycle
  times, schedule) are stored by one write. Selector `0x10` switches the
  port into the mode. Port on/off in the app is the `0x10` write alone.
- **Settings are a bundle.** Display unit, brightness, calibration and the
  rest always travel as one write. The app never sends a single field, so a
  client must read the whole bundle, change one item and write it all back.

The machine-readable spec is
[`device-specs/devices/acinfinity-uis-controller.yaml`](https://github.com/liberated-bread/liberatedbread-protocol-specs/blob/main/device-specs/devices/acinfinity-uis-controller.yaml).
It rests on two independent MIT-licensed projects:

- [Nyx000/acinfinity-ble](https://github.com/Nyx000/acinfinity-ble)
  recovered the protocol from the Android app, then re-checked it against
  the running app's own GATT writes (579 captured frames) and HCI snoops on
  a Controller 69 Pro and an 8-port AI power strip.
- [hunterjm/ac-infinity-ble](https://github.com/hunterjm/ac-infinity-ble)
  read a later app build and runs on a Controller 69 Pro.

Facts shown in Nyx000's captures are marked `confirmed` in the spec, and
facts from the app analysis alone are `reported`. This project has not
driven a unit.

**In scope:**

- The Controller 69 Pro and other multi-port controllers at protocol
  revision 6 or later. This is the primary target.
- The UIS power strip, for its status stream and outlet on/off only.
- Single-port controllers and revisions below 6, from the app analysis
  only.

**Out of scope:**

- The newer AI-series format, with two-byte item lengths and selector
  `0x61` sensor blocks.
- Wi-Fi provisioning over the separate
  `0000ffff-0000-1000-8000-00805f9b34fb` service.
- The AC Infinity cloud API.
- Firmware update.

!!! warning "Ports switch mains equipment"
    A mode, level or trigger written to the wrong port runs a heater or
    humidifier with nobody watching. Read the port back after every write.
    The spec offers only what the vendor app sends. The reset opcode and
    the settings nobody has exercised are not offered as commands, and the
    settings-bundle write is marked `advanced`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | CONTROLLER 69 PRO (CTR69P, device type 11, 4 ports); CONTROLLER 69 PRO+ (CTR69Q, type 18, 8 ports); CONTROLLER 69 (CTR69A, type 7); CONTROLLER 67 (CTR67A, type 1, single port); OUTLET AI / AI+ (AC-ADA4 / AC-ADA8, types 21 / 22), most likely the "8-port AI power strip" upstream used |
| Chipset | Not recorded. Upstream's two units carried Espressif OUIs (`80:f1:b2`, `d8:85:ac`), which suggests an ESP32-class radio (inference) |
| Radio | BLE, plus 2.4 GHz Wi-Fi on the 69 PRO, 69 PRO+ and OUTLET AI. The CONTROLLER 69 and 67 are Bluetooth only |
| Power | A controller is powered by the UIS device plugged into one of its ports. The strip plugs into the wall |
| FCC ID | 2AXMF-CTR69Q (CONTROLLER 69 PRO+, granted 2023-03-21); 2AXMF-CTR89 (CONTROLLER AI+, not covered). The 69 PRO's grant is not indexed under 2AXMF, but its IC ID is 29196-CTR69P |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (nothing is provisioned for BLE control) |
| Method | `ble_direct` |
| Advertised service | `70d51000-2c7f-4e75-ae8a-d758951ce4e0`, with manufacturer data under company `0x0902` |
| Passphrase protection | unknown (Wi-Fi provisioning is out of scope) |
| Confidence | medium (two working open clients; see the caveat below) |

On every connection, a client does the following:

1. Scan for service `70d51000-2c7f-4e75-ae8a-d758951ce4e0`, or for
   manufacturer data under company `0x0902` whose payload byte 12 is a
   covered device type. The controller **stops advertising while any
   central is connected**, so close the vendor app first.
2. Connect. Request an ATT MTU of 256, as the app does, or be ready to split
   writes into 20-byte pieces, as hunterjm's client does. Nothing bonds.
3. Enable notifications on `70d51002-2c7f-4e75-ae8a-d758951ce4e0`. **The
   device acts on writes, and answers them, only while a central is
   subscribed.** Status frames starting `1e ff 02 09` then arrive about once
   a second.
4. Optionally read the revision strings: firmware
   `00002a26-0000-1000-8000-00805f9b34fb`, hardware
   `00002a27-0000-1000-8000-00805f9b34fb` and software
   `00002a28-0000-1000-8000-00805f9b34fb`.
5. Write framed commands to `70d51001-2c7f-4e75-ae8a-d758951ce4e0`. Keep one
   command in flight and match its reply by the echoed sequence number. The
   app re-writes after 8 s without a reply and gives up after three retries.

**Caveat:** the manual's app pairing starts with holding the **port
button for 5 s** until the Bluetooth icon flashes. On Bluetooth+Wi-Fi units,
choosing Bluetooth in the app turns Wi-Fi off. Upstream's clients reconnect
to an already-paired controller without pressing anything. Whether a
factory-fresh unit, or one bound over Wi-Fi, advertises the control service
without the button hold is not established.

**Factory reset**:

- **Controllers:** hold **mode + up + down together for 5 seconds**. This
  clears every user parameter in every mode and setting. Source: the 69
  PRO, 69 and 67 manuals and the Other Settings guide.
- **OUTLET AI / AI+:** hold the **power button for 15 seconds**. The socket
  lights flash twice and stay lit. Source: the OUTLET AI manual.

Neither has been performed here, and neither manual says whether the reset
also forgets the app or Wi-Fi binding. BLE control needs neither.

**Rebinding**: there is no bond and no BLE credential. A new phone or
client needs only the controller to be free. The vendor app's account
binding lives in the cloud and does not gate the BLE protocol.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | none |
| One central at a time | Yes. The controller stops advertising while connected |
| One bond at a time | No (nothing is bonded) |
| Confidence | medium |

**Entering pairing mode**: this is not needed for a unit that is already
advertising. For the vendor app, hold the controller's port button for 5 s
until the Bluetooth icon flashes. On the OUTLET AI, hold the power button
for 5 s until it flashes green. The strip leaves pairing mode after 5
minutes, or when the button is held again. Whether a third-party client
ever needs this step is unknown (see the caveat above).

**Unpairing**: there is no bond to drop.

**Recovery**: close the vendor app or any other client that holds the link.
On Linux, a client that was killed can leave a stale BlueZ connection that
keeps the controller silent. Run `bluetoothctl disconnect <address>`, and
the controller advertises again about a second later.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `70d51000-2c7f-4e75-ae8a-d758951ce4e0` | UIS control service | Also the advertised service |
| `70d51001-2c7f-4e75-ae8a-d758951ce4e0` | Command frames | Write. The app writes with response, and both open clients write without response |
| `70d51002-2c7f-4e75-ae8a-d758951ce4e0` | Replies and status stream | Notify. Subscribe before the first write |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information (assumed) | Firmware, hardware and software revision strings |

A separate `0000ffff-0000-1000-8000-00805f9b34fb` service (write
`0000ff01-0000-1000-8000-00805f9b34fb`, notify
`0000ff02-0000-1000-8000-00805f9b34fb`) exists on Wi-Fi+BLE models for Wi-Fi
provisioning only. It is out of scope.

### Frame

| Bytes | Content |
|-------|---------|
| 0–1 | `a5 00`. Replies put a non-zero value in byte 1 (`13`, `17` and `1c` have been seen) |
| 2–3 | Payload length, u16 big-endian (the frame is payload + 12 bytes) |
| 4–5 | Sequence, u16 big-endian. The app adds 1 per command and wraps 65535 → 1. Replies echo it |
| 6–7 | CRC-16/CCITT-FALSE over bytes 0–5, big-endian |
| 8 | `00` |
| 9 | Opcode: `01` read, `03` write |
| 10… | Payload: `[selector][length][value]` items, then `ff <port>` |
| last 2 | CRC-16/CCITT-FALSE over byte 8 through the end of the payload, big-endian |

- **CRC**: poly `0x1021`, init `0xffff`, no reflection, no final XOR. The
  check value over `123456789` is `0x29b1`, the same as Python's
  `binascii.crc_hqx(data, 0xffff)`.
- **Port**: the port byte is the 1-based physical port, and `0` addresses
  the controller itself. Single-port controllers omit the `ff <port>`
  trailer.
- **Replies**: a write is acknowledged with `[selector, result]` pairs, where
  `0` means accepted and `1` rejected, followed by `ff <port>`.
- **Command templates**: the spec's templates are the span from byte 8 to the
  end of the payload. A client adds the envelope around them.

### Commands (all addressed with `ff <port>`)

| Command | Inner bytes (from byte 8) | Verification |
|---------|---------------------------|--------------|
| Switch active mode | `00 03 10 01 <mode> ff <port>` | confirmed |
| ON level (maximum) | `00 03 12 01 <level> ff <port>` | confirmed |
| OFF level (minimum) | `00 03 11 01 <level> ff <port>` | confirmed |
| AUTO triggers (revision ≥ 6) | `00 03 13 0a <sw> <hiF> <hiC> <loF> <loC> <hiRH> <loRH> <tgtF> <tgtC> <tgtRH> ff <port>` | reported |
| VPD triggers | `00 03 51 04 <sw> <hi> <lo> <target> ff <port>` (tenths of a kPa) | confirmed |
| Countdown then on / off | `00 03 14 04 <seconds u32 BE> ff <port>` / `00 03 15 04 …` | reported |
| Cycle | `00 03 16 08 <on s u32 BE> <off s u32 BE> ff <port>` | confirmed |
| Schedule | `00 03 17 04 <onH> <onM> <offH> <offM> ff <port>` (`ff` = unset) | confirmed |
| Read port | `00 01 10 11 12 13 14 15 16 17 ff <port>` | confirmed |
| Read VPD settings | `00 01 11 12 51 ff <port>` | reported |
| Settings bundle | `00 03 20 01 <unit> 21 02 <bright> <on> 24 03 <cal0> <calT> <calH> <other items> ff 00` | reported, advanced |

- **Mode numbers**:
  - 1: off (runs at the OFF level)
  - 2: on (runs at the ON level)
  - 3: auto (temperature and humidity triggers)
  - 4: countdown, then on
  - 5: countdown, then off
  - 6: repeating cycle
  - 7: daily schedule
  - 8: VPD triggers

  To change mode, write the mode's parameters first, then switch.
- **ON level**: above protocol revision 7 the ON-level byte packs the manual
  level in the high nibble and the maximum in the low nibble. Read it back
  and change only the nibble you mean.
- **AUTO block**: every temperature is sent twice, in whole °F and whole °C.
  A disabled bound keeps its rail value (194 °F / 90 °C, 32 °F / 0 °C, 100 %,
  0 %) with its bit clear. The switch bits are:
  - `0x08` high temperature
  - `0x04` low temperature
  - `0x02` high humidity
  - `0x01` low humidity

  Single-port controllers and revisions below 6 take a 7-byte block without
  the three target bytes. Upstream reports that its older client's 7-byte
  write to a revision-7 controller was answered as success and never stored.
- **VPD block**: trigger values are tenths of a kPa (1.4 kPa = `0x0e`),
  unlike the hundredths the status stream reports.

### Controller status stream (`1e ff 02 09`, 54 bytes on a 4-port 69 Pro)

| Bytes | Field |
|-------|-------|
| 0–3 | `1e ff 02 09` |
| 4 | Frame kind (`07` on a controller; meaning unknown) |
| 5 | Body length (frame = 6 + this) |
| 6 | Bit 7 = °C display; bits 6–5, 4–3 and 2–1 = temperature, humidity and VPD trend codes |
| 7 | Low nibble = the port the screen shows |
| 8–9, 10–11, 12–13 | Temperature °C, humidity %, VPD kPa. Each is int16 BE × 0.01, and `0x8000` = no probe |
| 14–17 | The controller's aggregate output record. Do not use it for per-port state |
| 22 + 8·(n−1) | Port n block: `[load id u16 BE, ffff = empty][run bits 7–6, level bits 5–2, output bit 1, fault bit 0][overcurrent bit 7, program bits 6–4, mode bits 3–0][3 unresolved bytes][load type]` |

Temperatures are °C on the wire whatever the display unit. Built for this
page (not captured), the frame `1e ff 02 09 07 30 80 01 08 ca 15 7c 00 7a …`
decodes as 22.50 °C, 55.00 % and 1.22 kPa.

### Power strip status stream (139 bytes)

The strip streams a different frame from the AI family, never to be decoded
with the controller layout:

- **Header**: byte 7's low 6 bits count the sensor records. In the 139-byte
  expanded header, the high nibble of byte 11 counts the port records
  (record 0 is the strip itself), and the low nibble of byte 12 counts the
  3-byte calibration records that start at byte 13.
- **Port records** follow, 10 bytes each:
  `[id u16][second id u16][load type][level bits 5–2, output bit 1, fault bit 0][mode][3 bytes]`.
- **Sensor records** follow the port records, 4 bytes each:
  `[sensor id][flags][int16 BE]`. They are scaled by the accuracy code in
  flag bits 6–5: 0 = ×10, 1 = ×1, 2 = ×0.1, 3 = ×0.01.
- **Sensor ids**: 0 = temperature °F, 1 = °C, 2 = humidity, 3 = VPD. 4–7
  are the same four for the zone sensor.

The two projects **disagree on outlet numbering**:

- **Nyx000's decoder** numbers outlets from the byte after each `3d b8 ff ff`
  run.
- **The app-derived layout** reads that byte as the load type, and the
  record's position as the outlet.

The position reading matches Nyx000's own fixture (a light on outlet 1, a
fan on outlet 2, a humidifier on outlet 5), so the spec uses it. For relay
state, the strip's reply to the app's controller-wide read (item `0x07`) is
the more trustworthy source.

### Settings bundle

Addressed to port 0, in this order:

1. `20` unit (1 = °C, 0 = °F)
2. `21` brightness (`[index 1–5, enable]`)
3. `24` calibration (`[byte 0 unresolved, temperature offset, humidity offset]`)
4. `11`, `12`
5. `26` buffer on/off
6. `22` transition
7. `23` buffer
8. `25` leaf-temperature offset
9. `50`, `53`, `28`, `70`

The meaning of `11` and `12` at port 0, and of `50`, `53`, `28` and `70`,
has never been exercised. Copy them byte for byte from a fresh read.
Calibration byte 0 fitted `round(offset × 9/5 + 32)` on two samples in °C
display. Copy it too rather than computing it.

### Advertisement (manufacturer data, company `0x0902`)

The payload is 17 or 27 bytes after the company ID:

| Bytes | Content |
|-------|---------|
| 0–5 | Device identity |
| 6–10 | Five ASCII characters of the unit's name suffix |
| 11 | Protocol revision |
| 12 | Device type (11 = 69 PRO, 18 = 69 PRO+, 21/22 = OUTLET AI / AI+) |
| 13 | Flags |
| 14 on | Live readings, in the 27-byte form only |

The SIG registry assigns `0x0902` to TSC Auto-ID Technology, not AC
Infinity. Match the service UUID as well.

### Test vectors

| What | Frame |
|------|-------|
| Port 1 → cycle, seq 0 (upstream golden) | `a5 00 00 05 00 00 47 c9 00 03 10 01 06 ff 01 ec be` |
| Read port 1, seq 0 (upstream golden) | `a5 00 00 0a 00 00 6b f8 00 01 10 11 12 13 14 15 16 17 ff 01 ff 2b` |
| Strip ack for a mode-and-level write (captured) | `a5 1c 00 06 00 00 91 e8 00 03 10 00 12 00 ff 01 16 29` |
| Port 2 → off, seq `0x0102` | `a5 00 00 05 01 02 54 ba 00 03 10 01 01 ff 02 59 4d` |
| Port 2 VPD high 1.4 / low 0.8 kPa, seq 7 | `a5 00 00 08 00 07 75 7f 00 03 51 04 03 0e 08 00 ff 02 26 3a` |
| Port 4 schedule 07:00 on / 19:00 off, seq `0x21` | `a5 00 00 08 00 21 31 db 00 03 17 04 07 00 13 00 ff 04 fc 56` |

The last three were built for this spec with the CRC above. More are in
`protocol_details.test_vectors`.

## Troubleshooting

- **The controller never shows up in a scan.** It does not advertise while
  anything is connected: the vendor app, Home Assistant, or a stale BlueZ
  link left by a killed client (clear it with `bluetoothctl disconnect`). If
  nothing is connected, try the 5-second port-button hold.
- **Writes are sent but nothing answers.**
  - Notifications on `70d51002-2c7f-4e75-ae8a-d758951ce4e0` were not
    enabled first.
  - A CRC is wrong, or the length field counts the whole frame rather than
    the payload.
  - A long frame was truncated at the default MTU. Request MTU 256, or
    split the frame into 20-byte writes.
- **The reply says success but the port keeps its old behaviour.**
  - Only the parameters were written. Switch the mode with selector `0x10`.
  - A 7-byte AUTO block went to a revision-6-or-later controller.
  - A single settings field was written instead of the bundle.
- **A port in OFF mode is still running.** OFF mode runs at the OFF level,
  which can be above zero.
- **The ON level reads back as `0x6a`.** That is the packed form used above
  revision 7: manual level 6, maximum 10.
- **Strip temperatures disagree between the stream and a query.** The
  stream carries °F (sensor id 0) and query replies carry °C.
- **A Node.js client on Linux keeps dropping the link
  (`le-connection-abort-by-local`).** Upstream hit this with node-ble on
  BlueZ, while bleak on the same host connected reliably.

## Open questions

- Whether a factory-fresh or Wi-Fi-bound controller advertises the control
  service without the port-button hold.
- Calibration byte 0, and whether the firmware (not just the app) ignores a
  single-field settings write.
- The settings items `0x50`, `0x53`, `0x28` and `0x70`, and `0x11`/`0x12` at
  port 0.
- A clean capture of one AUTO threshold changed on a port already in AUTO,
  and what AUTO bytes 7–9 do on the device.
- Controller port-block bytes 4–6 (cycle countdown, or error status).
- The strip's outlet numbering and its exact retail model.
- Reply byte 1, status-stream byte 4, and the trend codes.
- The reset opcode `0x08`, and the clock write's trailer.
- Anything captured from a 69 PRO+, a single-port controller or a unit below
  revision 6.

## Tools Used

- [x] Reading Nyx000/acinfinity-ble (docs, source, captured fixtures) and hunterjm/ac-infinity-ble (docs and decoders)
- [x] Reproducing both projects' golden frames with an independent CRC-16/CCITT-FALSE
- [x] AC Infinity manuals and web guides (CONTROLLER 69 PRO, 69, 67, OUTLET AI)
- [ ] A capture or a live run against a unit: **still needed**

## References

- [AC Infinity CONTROLLER 69 PRO user manual (CTR69P, PDF)](https://acinfinity.com/content/CTR69P2212X1_221215_CONTROLLER%2069%20PRO%20Manual.pdf)
- [AC Infinity CONTROLLER 69 PRO quick start guide (PDF)](https://www.acinfinity.com/content/CTR69P2305X1_230510_%20Quick%20Start%20Guide.pdf)
- [AC Infinity CONTROLLER 69 PRO+ quick start guide (CTR69Q, PDF)](https://www.acinfinity.com/content/CTR69Q2305X1_%20CONTROLLER%2069%20PRO%20Plus_Quick%20Start%20Guide.pdf)
- [AC Infinity CONTROLLER 69 user manual (CTR69A, PDF)](https://acinfinity.com/content/CTR692108X2_210827_CONTROLLER%2069%20Manual.pdf)
- [AC Infinity CONTROLLER 67 user manual (CTR67A, PDF)](https://acinfinity.com/content/CTR672109X1_210902_CONTROLLER%2067%20Manual.pdf)
- [AC Infinity OUTLET AI user manual (AC-ADA4 / AC-ADA8, PDF)](https://www.acinfinity.com/content/AI2407X1_240711_OUTLET%20AI%20Manual.pdf)
- [AC Infinity: Connecting to the app](https://acinfinity.com/pages/app-programming/connecting-to-the-app.html)
- [AC Infinity: Other settings](https://acinfinity.com/pages/controller-programming/other-settings.html)
- [AC Infinity: AUTO mode triggers](https://acinfinity.com/pages/controller-programming/auto-mode-triggers.html)
- [AC Infinity: VPD mode triggers](https://acinfinity.com/pages/controller-programming/vpd-mode-triggers.html)
- [Nyx000/acinfinity-ble (MIT)](https://github.com/Nyx000/acinfinity-ble), and its [wire protocol](https://github.com/Nyx000/acinfinity-ble/blob/main/docs/protocol/wire-protocol.md), [capture-verified findings](https://github.com/Nyx000/acinfinity-ble/blob/main/docs/protocol/app-ble-capture-verified-2026-06.md), [transport](https://github.com/Nyx000/acinfinity-ble/blob/main/docs/protocol/ble-transport.md), [read/notify decode](https://github.com/Nyx000/acinfinity-ble/blob/main/docs/protocol/read-notifications.md), [field map](https://github.com/Nyx000/acinfinity-ble/blob/main/docs/protocol/ble-packet-field-map.md) and [data model](https://github.com/Nyx000/acinfinity-ble/blob/main/docs/protocol/data-model.md) notes
- [hunterjm/ac-infinity-ble (MIT)](https://github.com/hunterjm/ac-infinity-ble) and its [protocol validation notes](https://github.com/hunterjm/ac-infinity-ble/blob/main/docs/protocol-validation.md)
- [FCC ID 2AXMF-CTR69Q (CONTROLLER 69 PRO+)](https://fccid.io/2AXMF-CTR69Q)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update](../protocols/firmware-update.md)

## Contributors

- Claude Code agent: spec written from two published open-source clients, their captures and the vendor manuals (no hardware)
