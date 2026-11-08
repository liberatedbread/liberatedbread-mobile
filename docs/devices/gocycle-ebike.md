# Gocycle G4 / G4i / G4i+ E-Bike (GocycleConnect BLE)

> **Status**: Spec Available (app-derived; not replayed against hardware)
> **Protocol**: BLE (Silicon Labs BGX13 Xpress Streaming Service carrying a framed 16-bit opcode protocol)
> **Manufacturer**: Karbon Kinetics Ltd (Gocycle)
> **Manufacturer Status**: Active

Machine-readable spec: `device-specs/devices/gocycle-ebike.yaml`. Where this page
and the spec disagree, the spec wins.

## Overview

Gocycle makes folding e-bikes. On the **G4 family** (G4, G4i, G4i+) the
GocycleConnect phone app is the only way to change riding modes, lights and
settings, and to see battery, speed and trip data. It also enforces account
sign-in and cloud registration before it will connect. This page documents
the bike's own Bluetooth LE protocol, so that a bike can be read and adjusted
without the vendor app.

The radio is a stock **Silicon Labs BGX13 "Bluetooth Xpress" module** used as a
serial bridge. Behind it, the bike's junction box and motor controller speak a
framed binary protocol with 16-bit opcodes. The same opcode set is older than
the BLE link: the **G2, G3, G3+, G3C, GS, GX and GXi** bikes carry it over
Bluetooth Classic SPP. That path is only summarised here.

What a client can do from the spec:

- poll the live **dash block**: battery %, voltage and current, speed,
  cadence, gear, odometer, trip distance, calories, moving time, pedal and
  motor energy
- read **versions**, the **identity** reply and the **hardware-type** byte
- switch the **front and rear lights**; set **DRL flashing**, the **DRL
  default mode** and the "DRL switch controls lights" selector
- toggle **predictive shifting** (G4i / G4i+)
- **reset the trip**
- read the **riding-mode definitions** and the **diagnostic counters**

**Riding-mode selection** (Eco / City / Turbo / Demand) is fully documented,
but the spec deliberately gives no ready-to-send frame for it. The record the
app writes to select a mode also carries that mode's **speed ceiling** and the
**pedalling-required** flag, which together set the bike's legal class. See
[Riding modes](#riding-modes).

!!! warning "Safety and scope"
    This spec controls a road vehicle's motor assistance and lights. Change
    settings only when the bike is stopped: the vendor manual warns against
    changing mode in motion. The following are **deliberately left out**, and
    named by role only: the writes for maximum speed and throttle (on-demand)
    permission, the miles and time limits, the frame number, factory state,
    the controller locks and the anti-theft flag, and every firmware-flashing
    step.

### Which Gocycles use BLE

The app picks the transport from the model code on the bike's **cloud build
record**. A code starting `G4` goes to the BLE scan, and anything else goes to
the Classic serial flow. Gocycle's own help centre splits the families the
same way. G4-family firmware is 2.x, while GXi/GX/G3/GS/G2 firmware is V8x.
Diagnostics have separate flows, and the Bluetooth-reset article covers only
G4, G4i and G4i+.

| Model | Link | Covered here |
|-------|------|--------------|
| G4, G4i, G4i+ (and the "Mk2" builds the app names) | BLE (BGX13) | Yes |
| GX, GXi, G3, G3+, G3C, GS, G2 | Bluetooth Classic SPP | Summary only |
| CX / CXi / CXi+ (cargo) | Not referenced by the app | Unknown |

### Evidence

Everything comes from static analysis of **GocycleConnect 9.6.2**. It is a
Capacitor app whose bike logic ships as plain JavaScript, so the frame builder,
the receive parser and every screen that sends a command were read directly.
Gocycle's manuals and help-centre articles supply the behaviour: riding modes,
Factory and Delivery State, the Bluetooth reset and the forced firmware
update. Silicon Labs' public BGX documentation identifies the GATT service and
the module's pairing defaults. There is **no capture**, and no FCC grant (none
is indexed for Gocycle or Karbon Kinetics, and no manual prints an FCC ID). No
open-source Gocycle client exists: an earlier note claimed a Home Assistant
integration, and it could not be found. Every fact is `reported`, and the
spec's `device.testing` is `untested`.

## Hardware

| Property | Value |
|----------|-------|
| Models covered | G4, G4i, G4i+ |
| Radio module | Silicon Labs BGX13 "Bluetooth Xpress" (identified by its stock Xpress Streaming Service) |
| Controllers | Junction box and motor controller behind the module; separate firmware versions |
| Advertised name | `Gocycle` + six-digit frame number (for example `Gocycle123456`); some units upper-case `GOCYCLE` |
| Radio power | Only while the battery is switched on; the battery turns itself off after about 30 minutes without motor activity |
| Firmware | G4 family 2.x. The app treats anything below 2.8 as needing an update |
| FCC ID | Not found (no grant indexed; not printed in the manuals) |

The frame number doubles as the bike's identity in the vendor's cloud: service
history, ownership and registration are all keyed on it.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No provisioning. A BLE bond is made on first connect (see Pairing) |
| Method | `ble_direct`, plus the vendor's `cloud_account` activation for a never-activated bike |
| Advertised name | `Gocycle…` / `GOCYCLE…` |
| Passphrase protection | not_applicable (no Wi-Fi) |
| Confidence | low (read from the app; not replayed) |

For an **activated** bike, the whole setup is: switch the battery on, close the
vendor app (and turn Bluetooth off on any other phone that uses the bike),
scan for the `Gocycle` name, connect, subscribe to Peripheral TX, and start
writing framed commands.

**A new bike is not usable until the vendor app activates it.** A bike shipped
directly is in **Factory State**, with the motor disabled. A dealer-prepared bike
is in **Delivery State**, with 60 miles (100 km) of assist. The owner's Setup in
the vendor app registers the bike and lifts the restriction. Those state
changes are writes this spec omits, so this spec cannot activate a bike. On a
used bike still registered to someone else, the vendor app refuses to connect
until the previous owner transfers ownership.

**Factory reset**: there is no owner-accessible factory reset. Factory and
Delivery State are activation states set by the vendor's dealer and factory
tooling. The only owner-side reset is the **Bluetooth reset**, which clears the
bike's stored bonds (see Pairing).

**Rebinding to a new phone or client**: in place. Disconnect the old phone and
pair from the new one. The BGX module keeps up to 14 bonds by default.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes (inferred) |
| Security mode | `just_works` (inferred) |
| Bonding | `required`: the bike stores bonds (inferred) |
| PIN source | None; no PIN appears anywhere in the app or documentation |
| One central at a time | Yes, per the vendor's multiple-devices article |
| One bond at a time | No. The module's bond table holds 14, and the vendor documents one bike on several phones |
| Confidence | low |

Silicon Labs documents the BGX streaming service as requiring an encrypted
link, with bonding requested by default. The app never calls a bond API and
never shows a PIN, so the phone's OS pairs implicitly on the first access to
the streaming characteristics, and Just Works is the expected model. The
vendor's instruction to "forget the Gocycle" in the phone after a bike-side
Bluetooth reset fits a bike that stores bonds. Gocycle could have reconfigured
the module, and one GATT session against a bike would settle it.

**Entering pairing mode**: not needed. The bike is connectable whenever its
battery is on.

**Unpairing (Bluetooth reset)**, per the vendor, needs firmware 2.3 or later:

1. Close the vendor app.
2. With the bike on, hold the **boost button** (G4) or the **left twist switch
   down** (G4i, G4i+) for **30 seconds**, until the bike beeps.
3. Forget the bike in every phone's Bluetooth settings, then pair again.

**Recovery**: if the bike is not visible or will not connect, close the vendor
app, turn Bluetooth off on any other phone that has used it, forget it in the
OS Bluetooth settings, and as a last resort do the Bluetooth reset.

## Protocol Summary

### BLE services

| UUID | Name | Role |
|------|------|------|
| `00001800-0000-1000-8000-00805f9b34fb` | Generic Access | `00002a00` Device Name gives the full `Gocycle<frame number>` name when the advertisement is truncated |
| `331a36f5-2459-45ea-9d95-6142f0c4b307` | BGX13 Xpress Streaming Service | Carries the bike protocol. Shared by every BGX13 product, so it is **not** an identification signal on its own |
| ↳ `a9da6040-0823-4995-94ec-9ce41ca28833` | Peripheral RX | Client → bike. Write every command here, **with response**. Leave its notifications **off** |
| ↳ `a73e9a10-628f-4494-a099-12efaf72258f` | Peripheral TX | Bike → client. Subscribe; every reply arrives here |
| ↳ `75a9f022-af03-4e41-b4bc-9de90a47d50b` | BGX Mode | The module's own mode switch (1 stream, 2 local command, 3 remote command). **Never write it** |

Enabling notifications on Peripheral RX switches the BGX into Fast-Ack flow
control, which sends 3-byte window messages on RX. The vendor app enables them
and then immediately disables them again, and ends up in legacy flow control
(RX notifications off, writes with response). A client should simply not
enable them.

The app's UUID table also lists two groups of Silicon Labs OTA UUIDs. The app
never uses them, and whether the bike exposes them is unknown.

### Frame format

Both directions on BLE use a long frame:

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 1 | `0x40` start byte |
| 1 | 2 | Payload length N, uint16 **little-endian** (payload only) |
| 3 | 2 | Opcode, uint16 **little-endian**; bit 15 set on the flagged opcodes below |
| 5 | N | Payload |
| 5+N | 2 | Checksum: uint16 LE sum of bytes 1 … 4+N (the start byte is not summed) |

- **Bit 15.** On send, the app sets bit 15 on the motor-controller opcodes
  (`0x2021`, `0x2022`, `0x2031`, `0x2035`, `0x2036`, `0x203f`, `0x2047`,
  `0x2049`, and some omitted writes). On receive it masks the bit off every
  opcode. A plausible reading is that the bit routes the frame to the motor
  controller, but that is a hypothesis.
- **Short frame.** The parser also accepts `0x21 <len C> <type> <C bytes>
  <sum8>`, where the checksum is the 8-bit sum of bytes 1 … 2+C. Only type
  `0x01` (ACK) is used, and it carries the acknowledged opcode.
- **ACK and NACK.** An ACK is opcode `0x0001` and a NACK is `0x0000`. Either
  carries the answered opcode as a uint16 LE payload.
- **Byte stream.** The BGX is a byte-stream bridge. Reassemble frames by the
  length field and verify the checksum before decoding. A frame can span
  notifications.

Test vectors:

| Frame | Decodes to |
|-------|------------|
| `40 00 00 31 a0 d1 00` | opcode `0x2031` (dash data, bit 15 set), no payload, sum `0x00d1` |
| `40 01 00 35 a0 04 da 00` | opcode `0x2035`, payload `04`, sum `0x00da` |
| `40 04 00 3c 10 ff 01 ff ff 4e 03` | opcode `0x103c` (set DRL), payload `ff 01 ff ff`, sum `0x034e` |
| `21 02 01 3c 10 4f` | short ACK of `0x103c` |

### Connection sequence

1. Connect. On a phone without a bond, the first access to the streaming
   service triggers pairing.
2. Subscribe to Peripheral TX (`a73e9a10-…`). Do **not** enable notifications on
   Peripheral RX.
3. Send `read_mc_version`. The app sends G4 bikes below 2.8 to its update page.
4. Send `read_max_speed`, then poll `read_dash_data` every **1000 ms**. The app
   stops polling after three unanswered polls.
5. On the first poll the app also reads the lights state and the active and
   custom mode definitions.

There is no login, key exchange or clock sync. The app's set-time command is
mis-wired and never reaches the bike.

### Commands

All frames are complete, including the checksum. Write them to Peripheral RX
as they stand.

| Command | Opcode | Frame | Reply |
|---------|--------|-------|-------|
| `read_dash_data` | `0x2031` | `40 00 00 31 a0 d1 00` | Dash block (below) |
| `read_mc_version` | `0x2021` | `40 00 00 21 a0 c1 00` | minor u16, major u16 |
| `read_jb_version` | `0x2026` | `40 00 00 26 20 46 00` | as above (unconfirmed on G4) |
| `read_id` | `0x1002` | `40 00 00 02 10 12 00` | `0x1003`: unit type, app/bootloader, version |
| `read_gocycle_type` | `0x204b` | `40 00 00 4b 20 6b 00` | byte 0: hardware type 1-5 |
| `read_mode_definition_active` | `0x2035` | `40 01 00 35 a0 04 da 00` | Mode definition 4 |
| `read_mode_definition_custom_1` / `_2` | `0x2035` | `…35 a0 02 d8 00` / `…35 a0 03 d9 00` | Custom modes (definitions 2, 3) |
| `activate_mode_slot` | `0x1009` | `40 01 00 09 10 03 1d 00` | ACK |
| `read_lights_enable` | `0x3023` | `40 00 00 23 30 53 00` | byte 0: 0 off, else on |
| `lights_on` / `lights_off` | `0x3022` | `40 01 00 22 30 01 54 00` / `…22 30 00 53 00` | ACK |
| `read_lights_selector` | `0x3020` | `40 00 00 20 30 50 00` | byte 0: 0 disabled, else enabled |
| `lights_selector_on` / `_off` | `0x3021` | `40 01 00 21 30 01 53 00` / `…21 30 00 52 00` | |
| `read_drl` | `0x103a` | `40 00 00 3a 10 4a 00` | `0x103b`: on, flash allowed, current mode, default mode |
| `drl_flash_on` / `_off` | `0x103c` | `40 04 00 3c 10 ff 01 ff ff 4e 03` / `…ff 00 ff ff 4d 03` | |
| `drl_default_*` | `0x103c` | `40 04 00 3c 10 ff ff ff <m> …` | m: 0 Low, 1 Low flashing, 2 High, 3 High flashing, 5 Off |
| `predictive_shifting_on` / `_off` | `0x3013` | `40 01 00 13 30 01 45 00` / `…13 30 00 44 00` | |
| `reset_trip` | `0x203f` | `40 05 00 3f a0 01 01 01 01 01 e9 00` | |
| `read_max_speed` | `0x2047` | `40 00 00 47 a0 e7 00` | mph × 100 (read only) |
| `read_allow_on_demand` | `0x2049` | `40 00 00 49 a0 e9 00` | non-zero = throttle-only assist permitted (read only) |
| `read_diagnostic_data` | `0x204a` | `40 00 00 4a 20 6a 00` | Sensor and switch counters |
| `read_stress_counts` | `0x3027` | `40 00 00 27 30 57 00` | 6 × float32 LE |

In `set DRL` (`0x103c`), a byte of `0xff` means "leave unchanged". The spec
has the full frames for every DRL default mode.

### Dash data (reply to `0x2031`)

Offsets are into the payload, which starts at frame offset 5. All multi-byte
fields are little-endian.

| Payload offset | Type | Field | Scale / unit |
|----------------|------|-------|--------------|
| 0 | u16 | Battery voltage | × 0.001 V |
| 2 | u16 | Battery current | × 0.001 A |
| 10 | u32 | Odometer | × 0.01 mi |
| 16 | u8 | Battery level | 0-10 → × 10 % |
| 20 | u16 | Trip calories | kcal (inferred) |
| 22 | u32 | Trip distance | × 0.01 mi |
| 28 | i16 | Miles limit (demo / Delivery State) | mi; −1 = none |
| 36 | u16 | Speed | ÷ 32 mph |
| 38 | u16 | Gear | |
| 40 | u16 | Cadence | × 0.1 rpm |
| 42 | u32 | Pedal energy since trip reset | J |
| 46 | u32 | Motor energy since trip reset | mJ |
| 50 | u32 | Moving time since trip reset | ms |
| 54 | u16 | Predictive shifting enabled | non-zero = on |
| 56 | u8 | Dealer review pending | |
| 58 | u16 | Service reminder pending | |

The app reads speed onward only when the payload is longer than 40 bytes,
energy onward only when it is longer than 46, and the last two flags only
when it is longer than 57. Current firmware sends at least 60 bytes (a
67-byte frame). Distances are always miles on the wire.

### Riding modes

The four mode buttons do not select a numbered mode. Each writes a
**pedal-power curve** into **mode definition 4** with opcode `0x2036` (sent as
`0xa036`), then sends `activate_mode_slot` (`0x1009`, payload `03`). The
definition record is the same 10 bytes the bike returns for `0x2035`:

| Payload byte | Field |
|--------------|-------|
| 0 | Definition number (app writes 4; G4 keeps Custom 1 and 2 in 2 and 3) |
| 1 | Torque-sensing flag (app writes 1) |
| 2 | Boost / power level (0 in every preset) |
| 3 | 0 = pedalling required, 1 = assist without pedalling allowed. **Region-dependent** |
| 4-5 | Speed ceiling, mph × 100, u16 LE. **Region-dependent** |
| 6-7 | Pedal effort at which assist starts, W, u16 LE |
| 8-9 | Pedal effort for full assist, W, u16 LE |

| Preset | Start (W) | Full (W) |
|--------|-----------|----------|
| City | 50 | 400 |
| Eco | 200 | 600 |
| Turbo | 50 | 200 |
| Demand | 600 | 600 |

The app identifies the active preset from definition 4's wattage pair, and
equal values mean Demand. It fills bytes 3-5 from the region on the cloud
record: the EU 25 km/h EPAC ceiling with pedalling required, or the 20 mph US
ceiling. A replacement client should instead **read definition 4, change only
bytes 6-9, and write it back**, with the bike stopped. Done that way, a mode
change can never raise the speed ceiling or enable throttle-only assist. The
spec declares the write as an `advanced` command with a byte layout but no
frame. The checksum is a 16-bit sum that the schema's template vocabulary
cannot yet compute, and the two copied fields need a read-back the vocabulary
cannot express.

### Firmware update

G4 images ship **inside the app** as Intel HEX (2.80, 2.86 and 2.87, chosen by
hardware type). The app streams them over the same framed channel. Nothing in
the app signs them, and whether the bootloader checks more than a CRC is
unknown. The vendor's **forced update** holds the boost button (G4) or the
left twist switch (G4i) while powering on, and is the documented recovery
after a failed update. The spec records only this role. The flashing opcodes
and bytes are intentionally absent.

### Bluetooth Classic bikes (G2 / G3 / GS / GX / GXi)

This is a summary only. The app lists bikes the phone has already paired in
its OS settings, then connects over SPP (`00001101-0000-1000-8000-00805f9b34fb`)
through the open-source cordova BluetoothSerial plugin. It writes **bare**
`[opcode high, opcode low, payload…]`: a big-endian opcode with no start byte,
length or checksum. It parses replies with the same `0x40` / `0x21` parser. No
source says whether that un-enveloped form is exactly what the bike accepts.
Firmware for these bikes is downloaded from the vendor's servers and flashed
over SPP. Whether the iOS app can reach them at all is unknown, because iOS
exposes no RFCOMM.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Bike not found in a scan | The battery is off (it auto-offs after 30 min idle), or another phone or the vendor app is connected. On Android, location or Bluetooth scanning is off |
| Pairing fails or drops at once | The phone holds a bond the bike has discarded (after a Bluetooth reset). Forget the bike and pair again. Firmware below 2.3 has no bike-side reset |
| Connected, but nothing answers | Wrong checksum or opcode byte order (the opcode is little-endian; check the bit-15 set). RX notifications left on (Fast-Ack). A reply split across notifications and not reassembled |
| Commands work, motor does not assist | Factory State (5 beeps) or unregistered/Delivery State used up (3 or 4 beeps). Only the vendor app's Setup clears it |
| Seven beeps at power-up | A dealer service rating is pending in the vendor app (dash `review_pending`) |

Known **vendor app** defects, which explain much of the store-review
frustration:

- The app requires sign-in, cloud ownership of the frame number and, on a new
  bike, registration before it will connect. Reviews report re-registration on
  reinstall and accounts that stop working.
- Its receive parser does not resynchronise cleanly after stray bytes. One bad
  notification can wedge it until reconnect.
- Its RX-subscribe, RX-unsubscribe, TX-subscribe sequence races. It works
  only because RX notifications end up off.
- The set-time and frame-number calls are mis-wired and never reach the bike.
- It splits frames over 150 bytes into 256-byte writes, above the BGX's
  250-byte limit.

## Open questions

- No GATT dump yet. The characteristic properties and pairing model are the
  BGX defaults, not observed.
- Does a 67-byte dash frame arrive in one notification at a phone's negotiated
  MTU?
- The meaning of bit 15, of the boost byte, of dash miles-limit −2, and of the
  dash bytes the app ignores.
- Which marketing model each hardware-type value 1-5 is, and whether the CX
  cargo bikes are G4-family BLE bikes.
- Whether the "Lights: Auto" state seen in an older app screenshot still
  exists. The analysed build offers only on/off.

## Tools Used

- Static analysis of the vendor app's JavaScript bundle
- Silicon Labs Gecko OS BGX documentation
- Gocycle manuals and help-centre articles
- A small Python transcription of the frame builder, used to compute and
  round-trip every frame in the spec

## References

- [Gocycle G4 manual, August 2024 (PDF)](https://gocycle.zendesk.com/hc/article_attachments/20875761767965): riding modes, custom-mode fields, battery and Bluetooth power, Factory/Delivery State
- [Gocycle G4i / G4i+ manual, August 2024 (PDF)](https://gocycle.zendesk.com/hc/article_attachments/20835029256477)
- [Gocycle help centre: G4 G4i G4i+ Bluetooth Reset](https://gocycle.zendesk.com/hc/en-us/articles/5732420283805-G4-G4i-G4i-Bluetooth-Reset)
- [Gocycle help centre: Connecting Multiple Gocycles and Devices](https://gocycle.zendesk.com/hc/en-us/articles/360001237194-Connecting-Multiple-Gocycles-and-Devices)
- [Gocycle help centre: Factory State and Delivery State](https://gocycle.zendesk.com/hc/en-us/articles/360002731157-Factory-State-and-Delivery-State)
- [Gocycle help centre: Beep Codes for Gocycle G4 and G4i](https://gocycle.zendesk.com/hc/en-us/articles/360021169298-Beep-Codes-for-Gocycle-G4-and-G4i)
- [Gocycle help centre: Force a Firmware Update](https://gocycle.zendesk.com/hc/en-us/articles/360002677018-Force-a-Firmware-Update)
- [Gocycle help centre: Firmware versions](https://gocycle.zendesk.com/hc/en-us/articles/5300344823965-Firmware-versions): EPAC and US Class 1/2 region classes
- [Gocycle help centre: App Diagnostics](https://gocycle.zendesk.com/hc/en-us/articles/115004909513-App-Diagnostics)
- [Silicon Labs Gecko OS BGX: BLE Services](https://docs.silabs.com/gecko-os/1/bgx/latest/ble-services)
- [Silicon Labs Gecko OS BGX: Security](https://docs.silabs.com/gecko-os/1/bgx/latest/security)
- [GocycleConnect on Google Play](https://play.google.com/store/apps/details?id=com.gocycle.Gocycle)
- [capacitor-community/bluetooth-le](https://github.com/capacitor-community/bluetooth-le): the BLE plugin the vendor app uses
- [don/BluetoothSerial](https://github.com/don/BluetoothSerial): the serial plugin behind the Classic path
- Related: [BlueDriver OBD-II scanner](bluedriver-obd2.md), another BGX13 product in this catalogue; [Pairing, Bonding and Unpairing](../protocols/pairing.md); [Firmware Update](../protocols/firmware-update.md)

The Zendesk article pages answer scripts with 403 but open in a browser.

## Contributors

- Liberated Bread project: initial static analysis and spec
