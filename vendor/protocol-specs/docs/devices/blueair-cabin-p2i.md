# Blueair Cabin P2i Car Air Purifier

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Blueair AB (BLE stack and SDK by Airboxlab, the company behind Foobot)
> **Manufacturer Status**: Active (the product is controlled locally over BLE, but the vendor app wants an account and uploads readings)

## Overview

The Cabin P2i is a 12 V purifier for a car. The purifier unit is strapped
behind a front-seat headrest. It holds a Particle+Carbon filter and a laser
particle sensor from the Plantower family. A 4.5 m cable runs from the unit to
a **control knob** that sits in the car's 12 V socket. The knob powers the
system, shows air quality and fan speed on a ring of LEDs, and has its own USB
charging port. The unit has a second USB port. The manual lists a twin-unit
**Cabin P2iD** beside it.

Inside the Blueair app the product is called **ICP**. Its Bluetooth side is
not Blueair's own work. The BLE SDK in the app was written by Airboxlab
(Foobot), and so was the firmware update service it uses. That lineage explains
the update-mode name "AirBoxLab" and why the firmware is hosted in a Foobot
storage bucket.

Everything a user can do from the app works locally over BLE with no cloud:

- fan speed (low, medium, high)
- fan mode (manual, auto)
- live PM1 / PM2.5 / PM10 and six particle-count bins
- filter life
- a fault bitfield
- a history of stored readings

The cloud account is only where the app sends those readings.

**Out of scope.** Blueair's Wi-Fi purifiers (Classic i-series, Sense+, Aware,
Blue Signature, HealthProtect 74xx/77xx, Blue Pure / Blue Max 211i–511i) and
its humidifiers and fans come through the same app, but none of them uses this
protocol. The app onboards them with Espressif protocomm over BLE (advertised
service `4772911e-d07c-4617-8241-f4d10948d6ae`) or through a SoftAP, and then
controls them through Blueair's cloud.

None of this has been driven against hardware by this project, and no capture
exists. Every byte below comes from static analysis of the Android app and of
two of the vendor's BLE-module firmware packages, plus the vendor manual. The
service layout, the security levels and the advertising data were read out of
the module's own firmware, which is as close to a GATT dump as you get without
the hardware, but still not one. In the spec it is all `reported`, and the
spec is `untested`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Cabin P2i (single unit). Cabin P2iD (two units) appears in the manual's performance table; its BLE identity is not known |
| Chipset | Three processors. **BLE module:** Nordic nRF52. The DFU packages target hw_version 52 and SoftDevice S132 v5.0.0, and a 220 KB application beside S132 only fits an **nRF52832**, so that part number is an inference. **Main MCU** in the purifier unit: the firmware the update package carries for it is an Arm Cortex-M image linked at `0x08000000`, the STM32 convention, so probably an STM32 or a clone (also an inference). **Knob MCU**, which the app and firmware call the "plug" |
| Sensor | Laser particle sensor, Plantower family (the BLE module's log strings name Plantower sensor errors). Exact model not established |
| Radio | BLE only (2.4 GHz). No Wi-Fi |
| Power | 12 V from the car's socket through the knob. The manual recommends an ignition-switched outlet |
| FCC ID | `2ARIK-P2I`, grantee Blueair Tech (Shenzhen) Co., Ltd. Filed 2018-11-06, equipment class DTS, 2402–2480 MHz Bluetooth LE. Details are from the fccid.io listing as a search engine indexed it; the site refuses scripted requests, so the exhibits were not retrieved |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. The only one-time step is the Bluetooth bond |
| Method | `ble_direct` |
| Setup AP / advertised name | Local name starting `Blueair P2i` (firmware 1.2.3 and 1.2.11) or `Blueair ICP`, matched case-insensitively as a prefix |
| Passphrase protection | not_applicable |
| Confidence | medium (decompiled app and vendor manual; not replayed here) |

To bring a unit up from a client:

1. Fit the filter and the top cover. The unit refuses to start without the
   cover. Plug the knob into the 12 V socket and switch the ignition on.
2. Flick the knob left or right once to turn the unit on. A blue LED on the
   top cover lights, and the fan resumes its last setting.
3. Turn the knob **clockwise and hold it for about 5 seconds**. The knob's
   LEDs run a cycling animation, which is pairing mode. Any phone already
   connected is dropped.
4. Scan for `Blueair P2i` / `Blueair ICP` and connect. The app scans for 30 s
   and takes the first match, not the strongest.
5. Bond, and wait for the bond to complete.
6. Request a larger ATT MTU. The app asks for 517. At least 41 is needed,
   because the stored-record notifications are 38 bytes.
7. Discover services and run the connect sequence under
   [Protocol Summary](#connect-sequence).

**Factory reset**: not established. The BLE module erases every bond when the
main MCU tells it to, and the main-MCU image inside the update package has a
factory-reset routine of its own. No gesture in the manual or the app is known
to reach either. Two things are easily mistaken for a reset:

- The **FILTER RESET** button on the purifier base only restarts the filter
  counter. The module's logs say it resets it to 360 h.
- Turning the knob **anticlockwise and holding for 3 s** only puts the unit
  into idle, with the lights off.

Nobody has worked out what clears the bond list. For anyone adopting a
second-hand unit, that is the open question.

**Rebinding to a new network**: not applicable, since there is no network.
To add a phone, repeat the knob pairing gesture. The unit keeps a bounded list
of bonded phones, and its logs show it replacing an entry when the list is
full.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes. The app always bonds before it touches a characteristic |
| Security mode | `just_works` (LE legacy pairing). From the module's firmware, not observed on air |
| Bonding | `required` |
| PIN source | None known |
| One central at a time | Unknown |
| One bond at a time | No. There is a bonded-peer list with a maximum size, which is not established |
| Confidence | medium (app flow, firmware log strings and the firmware's pairing parameters; the exchange itself was never observed) |

The firmware makes pairing mode matter more than usual. Once the unit holds
any bond, the BLE module advertises **only to whitelisted (bonded) phones**.
With an empty bond list and no pairing mode, it does not advertise at all. An
unbonded client can therefore get in only while pairing mode is active.

The firmware also settles how the pairing goes:

- **Pairing parameters.** Bonding is on, I/O capabilities are none, and LE
  Secure Connections is off. Keys are 7 to 16 bytes, and encryption and
  identity keys are distributed both ways. The module also sets the MITM and
  OOB flags, but a phone has no OOB data for it, so LE legacy pairing falls back
  to **Just Works** with unauthenticated keys.
- **Encryption is required.** Every custom characteristic value, and every
  CCCD, is registered with security mode 1 level 2: an encrypted link, with
  unauthenticated keys accepted. Without a bond, a read, write or subscribe is
  refused with an insufficient-encryption error, and most host stacks then pair
  on their own.
- **One exception.** The factory AT-command service `0x1337` drops the
  requirement while the unit is in its factory test-rig mode.

**Entering pairing mode**: with the unit on, turn the knob clockwise and hold
it for about 5 seconds, until the knob's lights cycle. The main MCU tells the
BLE module to enter pairing mode, and the module disconnects any current phone
and advertises to everyone. Pairing mode ends when a bond completes or when a
timeout runs out. The timeout's length was not recovered.

**Unpairing**: no user-facing route is known. The firmware can erase all bonds
when the main MCU asks, but nothing found here makes it ask. Forgetting the
unit on a phone clears only the phone's half.

**Recovery**:

- If another phone holds the link, close the vendor app or switch Bluetooth
  off on that phone. Entering pairing mode from the knob also drops it.
- If bonding fails after the unit lost its half of a bond, forget the unit in
  the phone's Bluetooth settings and repeat the knob gesture.

## Protocol Summary

### UUIDs: 16-bit shorts on the SIG base

Every custom UUID here is a 16-bit short on the Bluetooth SIG base,
`0000xxxx-0000-1000-8000-00805f9b34fb`, services and characteristics alike.
The shorts are not SIG-assigned. The app builds its characteristic UUIDs that
way and the module registers them that way, so write them exactly as expanded.

The app never names a service. It runs discovery and then addresses each
characteristic by its full UUID, and a client should do the same. The service
layout below comes from the module's own firmware, where each service is
registered as a primary service with a 16-bit UUID. It has not been seen in a
GATT dump.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00000001-0000-1000-8000-00805f9b34fb` | Identity, clock and status | Firmware versions, clock, fault flags, unit type, unit state (`0x0001`–`0x0005`). Always advertised |
| `00000002-0000-1000-8000-00805f9b34fb` | Fan and air quality | Fan speed and mode, run-time counters, stored records, live sensor frames (`0x0011`–`0x0017`). Advertised in normal operation |
| `00000003-0000-1000-8000-00805f9b34fb` | Update progress | `0x0060` only. Not advertised |
| `00001337-0000-1000-8000-00805f9b34fb` | Factory AT-command channel | `0x0040` / `0x0041`, for the factory test rig. **Leave it alone** (see below) |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information (SIG) | Serial, firmware and hardware revision, manufacturer |
| `0000fe59-0000-1000-8000-00805f9b34fb` | Nordic Secure DFU | Buttonless DFU entry |

Every characteristic in the four custom services carries a Characteristic
User Description with a short English label, so a GATT explorer shows names.
Every value is **fixed-length** in the module's table (the stack's
variable-length flag is off), so write exactly the length shown below.

### Characteristics

| UUID | Service | Properties | Length | Role |
|------|---------|------------|--------|------|
| `00002a25-0000-1000-8000-00805f9b34fb` | `0x180a` | read | text | Serial number and BLE address, UTF-8 `<serial>;<address>` |
| `00002a26-0000-1000-8000-00805f9b34fb` | `0x180a` | read | text | Firmware revision, UTF-8. The app replaces it with field 0 of `0x0001` |
| `00002a27-0000-1000-8000-00805f9b34fb` | `0x180a` | read | text | Hardware revision, UTF-8 |
| `00002a29-0000-1000-8000-00805f9b34fb` | `0x180a` | read | text | Manufacturer name, UTF-8 |
| `00000001-0000-1000-8000-00805f9b34fb` | `0x0001` | read | 84 | Firmware versions, UTF-8 `ble;main;knob;`, padded to 84 bytes |
| `00000002-0000-1000-8000-00805f9b34fb` | `0x0001` | read, write | 4 | Clock: Unix time in seconds, uint32 LE. The app writes it on every connection and never reads it |
| `00000003-0000-1000-8000-00805f9b34fb` | `0x0001` | read, notify | 4 | Fault flags (see below) |
| `00000004-0000-1000-8000-00805f9b34fb` | `0x0001` | read, notify | 1 | Single/duo unit type, probably. In the app's table but never accessed; code values unknown |
| `00000005-0000-1000-8000-00805f9b34fb` | `0x0001` | read, notify | 1 | Unit state (see below). **Firmware 1.2.11 and later only**; the app does not know it |
| `00000011-0000-1000-8000-00805f9b34fb` | `0x0002` | read, notify | 1 | Fan speed **reported** (what the unit is running) |
| `00000012-0000-1000-8000-00805f9b34fb` | `0x0002` | write | 1 | Fan speed **requested** |
| `00000013-0000-1000-8000-00805f9b34fb` | `0x0002` | read, notify | 1 | Fan mode **reported** |
| `00000014-0000-1000-8000-00805f9b34fb` | `0x0002` | write | 1 | Fan mode **requested** |
| `00000015-0000-1000-8000-00805f9b34fb` | `0x0002` | read, notify | 28 | Fan and filter run-time counters |
| `00000016-0000-1000-8000-00805f9b34fb` | `0x0002` | notify | 38 | Stored air-quality records. Notify only: it cannot be read, and the app subscribes and receives a burst |
| `00000017-0000-1000-8000-00805f9b34fb` | `0x0002` | notify | 26 | Live particle-sensor frames |
| `00000060-0000-1000-8000-00805f9b34fb` | `0x0003` | read, notify | 9 | Firmware-update progress |
| `00000040-0000-1000-8000-00805f9b34fb` | `0x1337` | write | 128 | Factory AT command. Do not write |
| `00000041-0000-1000-8000-00805f9b34fb` | `0x1337` | notify | 128 | Factory AT command response |
| `8ec90003-f315-4f60-9fb8-838830daea50` | `0xfe59` | write, indicate | – | Nordic buttonless DFU entry (without bond sharing) |

The properties and lengths of the custom characteristics come from the
module's GATT table. They agree with how the app uses each one, and add three
things the app never touches: `0x0002` is readable, `0x0004` is read/notify,
and there are the `0x0005` and `0x1337` characteristics. The Device
Information and DFU properties are the stack's defaults.

### Advertising

The firmware builds its advertising data from these parts:

- **Flags** `0x06`: LE General Discoverable, BR/EDR not supported.
- **Name**: `Blueair P2i`.
- **Appearance**: included. The value was not traced.
- **Complete list of 16-bit service UUIDs**: `0x0002, 0x0001` in normal
  operation. In the factory test-rig mode it is `0x0001, 0x1337` instead.

It advertises fast, then slow. Whenever it holds bonds and is not in pairing
mode, it filters by the whitelist. The spec leaves the service UUIDs out of its
scan matcher on purpose. They come from static analysis, and 16-bit values this
generic would pull in other hardware. Match on the name, as the app does.

### Factory AT-command service (`0x1337`)

The module carries a text channel into an AT-style command interpreter, for
the factory test rig. The same vocabulary runs its serial link to the main
MCU, and it reaches fan control, the filter counters, the clock, bond deletion
and the main-MCU and knob update steps.

At boot the module enters a test-rig mode when its stored settings are
uninitialised or its stored device ID is all zeros. In that mode the service is
advertised and open. On a unit that has left the factory it is present but
needs an encrypted link, like everything else.

Several of those commands can wipe state or leave a board without firmware.
None has been tried, and which of them this characteristic accepts was not
traced, so the spec declares no commands for it. A client should not use it.

### Connect sequence

This is the order the app uses after the bond, MTU request and service
discovery:

1. Read `0x0060` (update progress), then subscribe to it. While byte 0 is 2–5
   the unit is still updating its main MCU or knob. The SDK can hold
   everything else until byte 0 reads 1 (not needed) or 6 (finished). The
   shipped app does not use that option, but a careful client should wait.
2. Read `0x2a25`, `0x2a26`, `0x2a27`, `0x2a29` and `0x0001`, then `0x0003`,
   `0x0011`, `0x0013` and `0x0015`.
3. Write the phone's Unix time, as a uint32 LE, to `0x0002`.
4. Subscribe to `0x0003`, `0x0011`, `0x0013`, `0x0015` and `0x0017`.
5. Optionally subscribe to `0x0016`. The app does this only when a user is
   signed in, because it forwards the stored records to the cloud. It batches
   them in groups of up to 10 records or 10 s.

### Fan speed and mode

A write goes to the **requested** characteristic. The BLE module passes it to
the main MCU and then fetches the current value back, and the result arrives
as a notification on the **reported** characteristic. The knob and auto mode
change the same values, so render only the reported characteristic.

| Code | Fan speed (`0x0011` / `0x0012`) | Fan mode (`0x0013` / `0x0014`) |
|------|--------------------------------|-------------------------------|
| 0 | Defined, meaning unknown. The app never writes it and displays a reported 0 as low | Unknown |
| 1 | Low | Manual (the speed on `0x0012` applies) |
| 2 | Medium | Auto (the unit picks the speed from its sensor) |
| 3 | High | Max. Defined, but the app never writes it and the knob has no such position |

The app writes only speeds 1–3 and modes 1–2, and drops any reported value
that is not exactly one byte in the range 0–3. The spec offers speed 0 and
mode 3 only as `advanced` commands, because nobody has seen what the unit does
with them.

### Fault flags (`0x0003`, and bytes 8–11 of every stored record)

Four bytes, one per board. All zero means no fault.

| Byte | Bit | Meaning |
|------|-----|---------|
| 0 (purifier) | 0x01 | Top cover open or filter not seated. The unit will not run |
| 0 | 0x02 | Button fault |
| 0 | 0x04 | Battery fault |
| 0 | 0x08 | Particle sensor not responding |
| 0 | 0x10 | Particle sensor out of range |
| 0 | 0x20 | Malfunction |
| 1 (knob) | 0x01 | Knob not responding. Probably the manual's "disconnected from the control plug" |
| 1 | 0x02 | LED driver fault |
| 1 | 0x04 | Buttons fault |
| 1 | 0x08 | Malfunction |
| 1 | 0x10 | USB overload. The manual says the system shuts down until the load is removed |
| 2 (BLE module) | 0x01 | Lost contact with the main MCU |
| 3 (second unit, Duo) | 0x01 | Top cover open |
| 3 | 0x02 | Malfunction |

### Unit state (`0x0005`, 1 byte, firmware 1.2.11 and later)

The main MCU's operating state, which the BLE module keeps and notifies when it
changes. Firmware 1.2.3 does not have this characteristic, and the app never
uses it. The names are paraphrases of the firmware's own state-name table.

| Value | State |
|-------|-------|
| 0 | Unknown |
| 1 | Powered off |
| 2 | Starting up |
| 3 | Filter due |
| 4 | Normal |
| 5 | Going to standby |
| 6 | Standby |
| 7 | Pairing mode |
| 8 | Error |
| 9 | Firmware update |

### Run-time counters (`0x0015`, 28 bytes)

Seven 32-bit little-endian counters, all in minutes. The app decodes each one
as signed.

| Offset | Field |
|--------|-------|
| 0 | Minutes at speed 0 (meaning of "speed 0" not established) |
| 4 | Minutes at low |
| 8 | Minutes at medium |
| 12 | Minutes at high |
| 16 | Total fan-on minutes |
| 20 | Live minutes (probably total powered time) |
| 24 | **Filter time remaining.** 21600 (360 h) after a filter reset |

The manual rates a filter at about 360 hours of running, which it describes as
about 6 months at 2.5 h a day. The app shows filter life as **remaining × 100
/ 21600**, truncated to a whole percent and shown as 0 when remaining is 0 or
less.

### Stored record (`0x0016`, 38 bytes, all little-endian)

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 4 | Timestamp, Unix seconds, from the clock set through `0x0002` |
| 4 | 4 | Record number in the unit's data store |
| 8 | 4 | Fault flags (the `0x0003` layout) |
| 12 | 2 | PM1, µg/m³ |
| 14 | 2 | PM2.5, µg/m³ |
| 16 | 2 | PM10, µg/m³ |
| 18 | 2 | PM1, second figure |
| 20 | 2 | PM2.5, second figure |
| 22 | 2 | PM10, second figure |
| 24 | 2 | Count > 0.3 µm |
| 26 | 2 | Count > 0.5 µm |
| 28 | 2 | Count > 1 µm |
| 30 | 2 | Count > 2.5 µm |
| 32 | 2 | Count > 5 µm |
| 34 | 2 | Count > 10 µm |
| 36 | 1 | Fan speed (signed byte, the `0x0011` codes) |
| 37 | 1 | Fan mode (signed byte, the `0x0013` codes) |

The app drops any record that is not exactly 38 bytes.

### Live sensor frame (`0x0017`, 26 bytes)

| Offset | Length | Field |
|--------|--------|-------|
| 0 | 1 | Sensor status, signed. 0 = ok, −100 = CRC error, −102 = timeout; anything else is unknown |
| 1 | 1 | Not read by the app |
| 2–25 | 12 × 2 | The same twelve uint16 LE values as bytes 12–35 of the stored record |

The twelve values follow the order of the data words in a Plantower PMS frame.
If Plantower's convention holds, the first PM set is the "CF=1" figure, the
second is the "atmospheric environment" figure, and the counts are per 0.1 L
of air. That is a hypothesis. The frame carries no timestamp, and the app
shows the first PM set stamped with the phone's own clock.

### Update progress (`0x0060`, 9 bytes)

| Byte | Meaning |
|------|---------|
| 0 | Step: 0 not started, 1 not needed, 2 BLE module updating, 3 main MCU updating, 4 copying the knob image to the main MCU, 5 knob updating, 6 finished, 7 enum bound |
| 1 / 2 | BLE module: status, percent |
| 3 / 4 | Main MCU: status, percent |
| 5 / 6 | Knob image copy: status, percent |
| 7 / 8 | Knob: status, percent |

The status codes are 0 unknown, 1 not needed, 2 in progress, 3 finished and 4
enum bound. The app treats the unit as settled when the step is 1 or 6, or
when the knob stage reads finished.

### Firmware update

The update uses **Nordic Secure DFU**. The app hands the unit's address and a
package to the Nordic Android DFU library, with keep-bond set. The library
enters the bootloader through the buttonless characteristic
`8ec90003-f315-4f60-9fb8-838830daea50`, and the bootloader comes up at the
unit's **address + 1**. In update mode the unit advertises a name starting
`AirBoxLab`. The app also accepts a name starting `Dfu`, which is generic, so
tie it to this product only while an update you started is in progress.

The cloud tells the app where the package is. The app fetches it over plain
HTTP from `firmware.foobot.io`, a publicly listable Foobot/Airboxlab bucket
that also holds Blueair's other firmware. The two packages read for this spec
(application 1.2.3 and 1.2.11) are application-only and need S132 v5.0.0. They
carry an **ECDSA P-256 signed** init packet, so a replacement client can
deliver the vendor's packages but cannot build its own. Both packages declare
application version 0, so the bootloader's version check will not tell
releases apart.

The BLE module's application image carries the main MCU's firmware inside
it: there are embedded Arm Cortex-M images with vector tables linked at
`0x08000000`. Where the knob's image sits was not traced. After the BLE module
reboots, the unit carries on by itself. It pushes new
firmware to the main MCU and then to the knob, reporting each stage on
`0x0060`, and the knob glows green meanwhile. The manual says not to power the
unit off until it restarts. The spec marks the bootloader entry as `advanced`
and reproduces no image or init-packet bytes.

The app has a separate path for resuming an update on a unit it finds already
in update mode. By flash arithmetic, a 220 KB application beside S132 on an
nRF52832 leaves no room for a second bank. An interrupted transfer therefore
probably leaves the unit in its bootloader. Getting it out needs a Nordic DFU
client and the vendor package.

## Troubleshooting

- **Scan finds nothing.** The unit advertises only to phones it has bonded
  with, and not at all when it has no bonds. Put it into pairing mode with the
  knob (clockwise, about 5 s). Also check that the 12 V socket is live with
  the ignition on and that the top cover is seated.
- **Bonding fails or the link drops right after connecting.** Pairing mode was
  not active or had timed out. Repeat the gesture. If the phone remembers an
  old bond, forget the unit first.
- **Reads or subscriptions fail with an insufficient-encryption (or
  authentication) error.** Every custom characteristic needs an encrypted
  link. Bond first; most stacks start pairing on this error by themselves,
  but some need it asked for explicitly.
- **Stored-record or counter notifications are cut short.** The MTU was not
  raised. At the default MTU a notification carries 20 bytes, and the app
  drops anything that is not exactly 38 or 28 bytes.
- **Filter life never updates after a filter change.** The counter resets only
  from the **FILTER RESET** button on the purifier base. No BLE command for it
  is known.

Defects found in the vendor app, which a replacement client should not copy:

- The fault-flag parser accepts a 3-byte value and then reads a fourth byte,
  which throws.
- The live-frame parser has no length check. A short frame throws and ends the
  stream until the next connection.
- The live-frame status table includes −200 (sensor not initialised), which
  the signed byte it reads cannot represent.
- Onboarding takes the first matching advertiser within its 30 s scan. With
  two units in pairing mode it can bond the wrong one.
- Stored records are collected only while a user is signed in, because they go
  to the cloud. A phone used only locally never drains them.
- Resuming an interrupted update looks the unit up in the cloud account's
  device list. Without the cloud, a stuck unit needs a generic Nordic DFU tool
  and the package.

## Tools Used

- [x] Static analysis of the Blueair Android app (v4.x, 2026-09), covering
  its embedded Cabin BLE SDK and the app layer that drives it
- [x] Static reading of two Cabin P2i BLE-module DFU packages from the
  vendor's public bucket: manifests, init-packet structure and log strings. No
  bytes are reproduced
- [x] A disassembly of the 1.2.11 BLE-module application's BLE setup code:
  the GATT table (services, properties, lengths, security levels), the
  advertising data and the pairing parameters
- [x] The vendor's Cabin P2i user manual (English/Japanese, 2018)
- [ ] nRF Connect against a real unit, to confirm the service layout,
  properties, advertising data and pairing method read from the firmware:
  **still needed**

## References

- [Blueair Cabin P2i car air purifier user manual (PDF, EN/JA, Blueair Japan)](https://www.blueair.jp/wp-content/uploads/2019/05/501128_P2i.pdf)
- [Blueair Cabin P2i manuals (ManualsLib)](https://www.manualslib.com/products/Blueair-Cabin-P2i-9273796.html)
- [FCC ID 2ARIK-P2I (fccid.io)](https://fccid.io/2ARIK-P2I)
- [nordicsemi/Android-DFU-Library](https://github.com/nordicsemi/Android-DFU-Library), the DFU library the app embeds
- [NordicSemiconductor/pc-nrfutil](https://github.com/NordicSemiconductor/pc-nrfutil), the DFU package format and a desktop DFU client
- [Plantower PMS5003 data manual (PDF)](https://www.aqmd.gov/docs/default-source/aq-spec/resources-page/plantower-pms5003-manual_v2-3.pdf), for a sibling sensor's data-word order
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update (DFU / OTA)](../protocols/firmware-update.md)
- [Common BLE Patterns](../protocols/ble-common.md)

## Contributors

- Claude Code agent: spec written from static analysis of the vendor app and firmware packages plus the vendor manual (no hardware)
