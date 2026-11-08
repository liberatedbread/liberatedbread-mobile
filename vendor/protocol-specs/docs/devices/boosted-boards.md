# Boosted Boards and Boosted Rev (app BLE profile)

> **Status**: Spec Available (static analysis of the last vendor Android app; no capture, not run against hardware)
> **Protocol**: BLE
> **Manufacturer**: Boosted Inc. (shut down 2020; the remaining inventory was bought by Boosted USA, a separate company)
> **Manufacturer Status**: Shutdown

## Overview

Boosted made electric skateboards: the 1st-gen Single, Dual and Dual+,
the 2nd-gen Dual and Dual+, the 3rd-gen Plus and Stealth, and the Mini S
and Mini X. It also made the Boosted Rev scooter. The company stopped
trading in 2020, its app is gone from the stores, and its servers are
offline. Owners still ride these boards in large numbers.

A board has two radio links. The handheld remote drives the board over
its own BLE link, and that riding link is **out of scope** here. The
community has documented it (see [References](#references)). This page
covers the other link, **phone to board**. The vendor app used it to show
speed, odometer, battery and charging state, pick a ride mode, rename the
board, set display units and drive the lights. That link is plain GATT
straight from the phone and never needed the cloud. The cloud handled
accounts, ride logs, the inbox and firmware hosting, so everything on this
page still works with the servers gone.

The machine-readable spec is
[`device-specs/devices/boosted-boards.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/boosted-boards.yaml).
Every fact in it is `verification: reported`. The characteristics, value
layouts and writes come from static analysis of the final Android release
of the vendor app (1.4.5, December 2019). Two placements are backed by
owners reading real hardware with a generic BLE explorer, as reported in the
[Forever Boosted FAQ](https://foreverboosted.co/faq): the Device Information
service and the battery service UUID. Nobody on this project has connected
to a board.

!!! danger "A ride-mode write changes a moving vehicle"
    These boards reach about 38 km/h. A ride-mode write changes acceleration
    and top speed the moment it lands. The spec documents only what the
    vendor app did, which is picking one of the firmware's own modes, and marks it
    `advanced`. Send it only with the board stopped and nobody on it.
    Speed-cap changes, battery limits and the firmware-flashing protocol are
    deliberately left out.

**In scope:** the phone-app GATT profile of 2nd/3rd-gen boards and the Rev.
The 1st-gen boards are identified here, but their serial payload is not mapped.

**Out of scope:** the remote-to-board riding link; firmware and bootloader
frames on the serial characteristics; anything beyond the firmware's own
ride modes; and the dead cloud API.

## Hardware

| Property | Value |
|----------|-------|
| Models | 2nd gen: Dual, Dual+ · 3rd gen: Plus, Stealth · Mini S, Mini X · Boosted Rev scooter · 1st gen (identification only): Single, Dual, Dual+ |
| Model codes (7dc59643) | 1 Dual, 2 Dual+, 3 Plus, 4 Stealth, 5 Mini S, 6 Mini X, 7 Rev, 0 unknown |
| Chipset | Not recorded for 2nd/3rd gen. The 1st-gen boards use a BlueRadios module running its BRSP serial-port service |
| Radio | Bluetooth LE: the phone link here, plus a separate BLE link to the remote |
| Last firmware | ESC 2.7.2 and extended-range battery 2.5.1, per the owner community. Official images are no longer downloadable |
| FCC ID | Not harvested. No Boosted grantee turns up on fccid.co, so the boards probably rely on module grants |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No. Boards ride out of the box with their remote. The phone link needs only a bond |
| Method | `ble_direct` (primary). The vendor account and registration route is `historical`, because its servers are gone |
| Advertised service | `7dc55a86-c61f-11e5-9912-ba0be0483c18` (the app's own scan filter) |
| Advertised name | The owner-editable board name, so not a matcher |
| Passphrase protection | not_applicable |
| Confidence | medium (vendor support article plus the app's code; not replayed) |

On every connection the vendor app did the following:

1. Scan in low-latency mode for `7dc55a86-c61f-11e5-9912-ba0be0483c18`.
   Boards in pairing mode are listed first. Pairing mode is bit `0x02` of
   the first manufacturer-data byte.
2. If the phone holds no bond, ask the OS to bond and wait. The app never
   opens GATT to an unbonded board. On boards whose advertised firmware
   is older than v2.0.0, it deleted the phone's bond first and bonded
   again every time.
3. Connect, with a 45 s timeout. Read every characteristic it knows that
   the GATT table actually contains.
4. Depending on the Firmware Revision String, read the battery pack ID
   and firmware, or ask the serial pipe for them (see
   [Firmware gates](#firmware-gates)).
5. Subscribe to mode, odometer, speed, battery remaining and charging,
   plus lights status where it exists.

After a disconnect the app retries in 1 s. After a missing
characteristic or a failed notification setup it retries in 10 s. Before
reconnecting it refreshes Android's cached GATT table.

The vendor account was optional ("Not now"). It was needed only for
firmware updates and ride sharing, and it can no longer be created.

**Factory reset**: unknown. No vendor article or community source in the
research describes a board-side reset that clears phone bonds, the board
name or settings. The spec records `applicable: "unknown"`. Do not
experiment with button combinations on a board you intend to ride.

**Rebinding**: there is no network membership. A new phone bonds after the
board is put back into pairing mode. Nothing needs the old phone.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | Yes. The vendor app always bonds before connecting. Whether the board refuses an unbonded central is not recorded |
| Security mode | unknown. The app supplies no PIN and lets the OS finish the bond, which points to Just Works |
| Bonding | `required` |
| PIN source | None requested by the vendor app |
| One central at a time | Unknown |
| One bond at a time | Unknown |
| Confidence | medium |

**Entering pairing mode**: with the board on, press its power button **five
times**. The button LED flashes blue, and the advertisement's pairing
flag is set. This comes from the vendor's archived "How to Update Your
Board's Software" article and the app's own prompts. How long the window
stays open is not recorded. The same five presses also start remote pairing.

**Unpairing**: forget the board in the phone's Bluetooth settings. No
board-side way to drop a bond is documented.

**Recovery**: close the vendor app on any other phone that is in range,
forget the board in this phone's Bluetooth settings, re-enter pairing mode
and bond again. 2nd-gen, Mini, Plus and Stealth boards accept the app and
the remote at the same time. A 1st-gen board takes one or the other.

## Protocol Summary

### Generations

| Advertised service | App's label | Covers | Confidence |
|---|---|---|---|
| `7dc55a86-c61f-11e5-9912-ba0be0483c18` | "V2" | 2nd-gen Dual/Dual+, Plus, Stealth, Mini S, Mini X; the Rev by the app's logic | reported |
| `da2b84f1-6279-48de-bdc0-afbea0226079` | "V1" | 1st-gen boards. This is BlueRadios' stock BRSP serial-port service | reported |
| `ea32b817-d410-42e2-848a-1218201468fc` | scooter | Boosted Rev, checked on top of the V2 match by a helper the examined release never calls | reported |

An older note in this repository mapped these the other way round. The
BRSP identification settles it: `da2b84f1` is the 1st-gen serial pipe. It
still wants a look at real hardware. Never match on `da2b84f1` alone. It is
a generic module service that unrelated products also carry.

### BLE Services

| UUID | Name | Placement evidence |
|------|------|-------------|
| `7dc55a86-c61f-11e5-9912-ba0be0483c18` | Vehicle service | Advertised. The `7dc5…` characteristics share its base, so placement is probable |
| `65a8eaa8-c61f-11e5-9912-ba0be0483c18` | Battery service | Owners' own reads with a BLE explorer (community FAQ) |
| `ea32b817-d410-42e2-848a-1218201468fc` | Lights service | Inferred from the shared base |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Owners' own reads (Firmware Revision String) |
| `da2b84f1-6279-48de-bdc0-afbea0226079` | BlueRadios BRSP (1st gen) | Identification only |

The app never names a service. It finds every characteristic by UUID
across the whole table, so a client should do the same.

### Vehicle characteristics (`7dc5xxxx-c61f-11e5-9912-ba0be0483c18`)

All values are little-endian.

| Characteristic | Properties | Layout | Meaning |
|---|---|---|---|
| `7dc5bb39-…` vehicle_id_name | read, write | text, NUL-padded | Read: the board's name/identifier, trailing NULs stripped. Write: rename (below) |
| `7dc59643-…` vehicle_model | read | u8 | Model code, see [Hardware](#hardware). Selects the scales below |
| `7dc55dec-…` vehicle_modes_count | read | u8 | How many ride modes the firmware offers, from Beginner |
| `7dc55f22-…` vehicle_mode | read, write, notify | u8 | 0 Beginner, 1 Eco, 2 Expert, 3 Pro, 4 Hyper. The app shows these as 1–5, and any other value as Eco |
| `7dc56594-…` vehicle_odometer | read, notify | u32 LE | Lifetime count × per-model factor = miles |
| `7dc56b34-…` vehicle_speed | read, notify | s16 LE | Count × per-model factor = mph. Negative values are shown as 0 |
| `7dc56bfc-…` vehicle_power | unknown | unknown | Known to the app, never read |
| `7dc5c19d-…` vehicle_units | read, write | u8 | 0 US (mi, mph), 1 metric (km, km/h). Meaningful on the Rev's display |
| `7dc5c201-…` motor_driver_serial | read | bytes | Shown by the app as uppercase hex |
| `7dc5c202-…` motor_driver_firmware | read | 3 × u8 | Printed as byte0.byte1.byte2 |
| `58856524-0065-11e6-8d22-5e5517507c66` serial_command | read, write, notify | text lines | Firmware-update pipe (below). Parent service unknown |
| `58856525-0065-11e6-8d22-5e5517507c66` serial_auth | read | u8 | Non-zero first byte = pipe unlocked |

### Per-model scales

| Model code | Odometer (mi per count) | Speed (mph per count) |
|---|---|---|
| 1, 2, 5, 6 (Dual, Dual+, Mini S, Mini X) and 0 | 3.6128e-5 (≈ 5.8 cm) | 0.0028409092 (1/352 mph = 0.05 in/s) |
| 3, 4 (Plus, Stealth) | 3.8386e-5 (≈ 6.2 cm) | 0.0028409092 |
| 7 (Rev) | 6.2137273665e-4 (1 m) | 0.00223694 (1 mm/s) |

The Plus/Stealth odometer factor is 1.0625 times the others, the ratio of
85 mm to 80 mm wheels. That points to a wheel-rotation count, but it is an
inference.

Worked examples, which the spec carries as test vectors:

| Characteristic | Model | Bytes | Decoded |
|---|---|---|---|
| speed | 4 (Stealth) | `c0 0d` | 3520 → 10.0 mph |
| speed | 7 (Rev) | `10 27` | 10000 → 22.37 mph (10 m/s) |
| odometer | 1 (Dual) | `40 42 0f 00` | 1,000,000 → 36.128 mi |
| odometer | 3 (Plus) | `40 42 0f 00` | 1,000,000 → 38.386 mi |
| odometer | 7 (Rev) | `40 42 0f 00` | 1,000,000 → 621.37 mi (1000 km) |

### Battery characteristics (`65a8xxxx-c61f-11e5-9912-ba0be0483c18`)

| Characteristic | Properties | Layout | Meaning |
|---|---|---|---|
| `65a8eeae-…` battery_remaining | read, notify | u8 | State of charge, % |
| `65a8f5d4-…` battery_charging | read, notify | u8 | 0 = not charging, non-zero = charging |
| `65a8f3c2-…` battery_capacity | read | u32 LE | Raw capacity count, physical unit unknown. The app's range factor is raw / 2,400,000 below 3,000,000 and raw / 2,000,000 at or above it (the extended-range pack) |
| `65a8f834-…` battery_id | read | bytes | Pack ID, shown as uppercase hex |
| `65a8f833-…` battery_firmware | read | 3 × u8 | Printed as byte0.byte1.byte2 |

The pack ID and firmware characteristics exist from ESC firmware v1.5.0.

### Lights characteristics (`ea32xxxx-d410-42e2-848a-1218201468fc`)

These drive the Rev's built-in lights and the Boosted Beams head and brake
lights for boards (Beams support arrived with ESC 2.7.x, per the community).
They are absent on a vehicle without lights support.

| Characteristic | Properties | Layout | Meaning |
|---|---|---|---|
| `ea32dcac-…` lights_status | read, write, notify | u8 | 0 off, 1 on. 2 "automatic" is in the app's value set but never offered |
| `ea32b761-…` lights_default_mode | read, write | u8 | 1 = lights on at power-up, 0 = only when switched on |
| `ea326b96-…` lights_brightness | read, write | u8 | 0–100 %. The app writes multiples of 5 |
| `ea324d8c-…` brake_lights_pattern | read, write | u8 | 1 = blink when braking, 0 = steady |

### Device Information

| Characteristic | Meaning |
|---|---|
| `00002a26-0000-1000-8000-00805f9b34fb` Firmware Revision String | ESC firmware, `vX.Y.Z`. The app's version gates use it |
| `00002a25-0000-1000-8000-00805f9b34fb` Serial Number String | Known to the app as the scooter serial, never read |

### Commands

Every write is a plain GATT write with no preceding handshake, no framing and
no checksum.

| Command | Characteristic | Bytes | Notes |
|---|---|---|---|
| `set_ride_mode` | `7dc55f22-…` | `[mode]`, 0–4 | **advanced**. Only indices below `modes_count`, only while stationary. Read first to be able to undo |
| `set_units` | `7dc5c19d-…` | `[0]` US / `[1]` metric | |
| `rename_vehicle` | `7dc5bb39-…` | raw UTF-8, no terminator | Must not be blank. Maximum length not recorded |
| `set_lights_power` | `ea32dcac-…` | `[0]` / `[1]` | The remote's double press also switches the lights. That it is the same state is an inference |
| `set_lights_startup` | `ea32b761-…` | `[0]` / `[1]` | |
| `set_lights_brightness` | `ea326b96-…` | `[0..100]` | Percent |
| `set_brake_light_pattern` | `ea324d8c-…` | `[0]` steady / `[1]` blink | |

The app's mode picker shows these top speeds, which are its own display
constants: Beginner 18 km/h, Eco 25, Expert 32, Pro 35, Hyper 38 (Rev: 19.3,
29, 38.6). The firmware enforces the real caps. They vary by board, and the
vendor's store screenshot of a 3rd-gen board shows 22/26/32/35/39 km/h. How
many modes a board offers is in `modes_count`, which varies by model and
firmware. The app
also computes a range estimate from charge, the capacity factor, the mode
and rider settings. The spec's `protocol_details.range_estimate` holds the
formula and coefficients.

### Advertisement

The first manufacturer-specific AD structure is read before connecting.
Offsets count from the first byte of the AD value.

| Bytes | Meaning |
|---|---|
| 0–1 | Flags where a company ID would sit. Bit `0x02` of byte 0 = pairing mode. Do not filter on these bytes |
| 2 | Firmware patch |
| 3 | Firmware minor |
| 4 | Firmware major. The app shows `v<major>.<minor>.<patch>` |

Example: `02 00 02 07 02` is a board in pairing mode on v2.7.2. The app
also takes a 4-byte motor-driver serial from raw scan-record bytes 34–37
(reversed, as hex). That position depends on Android's scan-record buffer
and is unverified on air.

### Firmware gates

| Version | Read from | Effect in the vendor app |
|---|---|---|
| < v1.4.2 | Firmware Revision String | No battery pack ID or firmware at all |
| v1.4.2 up to v1.5.0 | Firmware Revision String | Pack ID and firmware requested over the serial pipe (25 s timeout) |
| ≥ v1.5.0 | Firmware Revision String | Pack ID and firmware characteristics read. Serial-pipe writes framed (not mapped) |
| ≥ v1.6.0 | Firmware Revision String | Serial pipe locked behind a challenge answered by Boosted's servers |
| < v2.0.0 | advertisement | Phone bond deleted and redone before every connection |

### Serial pipe and firmware updates

The vendor app updated firmware over `58856524`/`58856525` with Boosted's
own bootloader protocol, not Nordic DFU. The app bundles no Nordic DFU or
MCUmgr library. The images came from Boosted's servers. Commands are lines
of text ending in CR, and replies arrive as notifications ending in CRLF.
One of them is a version query, `ALLFW`. From ESC firmware v1.5.0 the app
frames its writes. From v1.6.0 it must first read a challenge from
`58856524-0065-11e6-8d22-5e5517507c66`, send it with the board ID to
Boosted's servers, and write the answer back. Those servers are gone. The
framing and the bootloader frames are **deliberately not documented** here.
A half-flashed ESC is a board nobody can ride.

### 1st-gen boards (BRSP)

The service `da2b84f1-6279-48de-bdc0-afbea0226079` is BlueRadios' serial
port. Its characteristics carry BlueRadios' published roles: info
`99564a02-dc01-4d3c-b04e-3bb1ef0571b2`, mode
`a87988b9-694c-479c-900e-95dfa6c00a24`, RX (app to board)
`bf03260c-7205-4c25-af43-93b1c299d159`, TX (board to app, indicate)
`18cda784-4bd3-4370-85bb-bfed91ec86af`, RTS flow control
`fdd6b4d3-046d-4330-bdec-1fd0c90cb43b`, and CTS
`0a1934f5-24b8-4f13-9842-37bb167c6aff`, which the app names but never
uses. The byte stream over RX/TX is **not mapped**. The vendor's 2014
insert gives the 1st-gen modes: Dual has Beginner 11 mph, Eco 16 mph and
Expert 20 mph, and Dual+ adds Pro at 22 mph. On these boards the mode is
cycled with three presses of the remote's button.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Phone keeps asking to pair, or connects once then refuses | Firmware older than v2.0.0 (the app worked around a bonding defect by re-bonding every time), or another phone still holds the connection. Forget the board, re-enter pairing mode, bond again |
| Battery pack ID and firmware never appear | ESC firmware older than v1.5.0. The details come over the serial pipe on v1.4.2 up to v1.5.0, and not at all before |
| Extended-range pack flashes its power button white | The board needs the software update that activates extended-range packs, and that update came from the dead servers |
| The vendor app shows Eco for an odd mode byte | The app shows any value outside 0–4 as Eco. Read the raw byte |
| Hyper (mode 5) has vanished | An ESC fault described by the owner community, which locks out the fifth mode after connecting to the vendor app. It is fixed by ESC work, not over this link |
| Firmware update impossible | The images and, from v1.6.0, the serial-pipe challenge both depended on Boosted's servers |

## Remaining unknowns

- Nothing has been checked on hardware. That includes the generation
  mapping, the Rev's advertised services (the app's scan filters imply it
  advertises `7dc55a86` too) and the parent services of the vehicle, lights
  and serial characteristics.
- The pairing association model, whether the board enforces the bond, how
  many bonds it keeps, and how long the pairing window lasts.
- The unit of the capacity count, the lengths of the serial and pack ID
  values, the maximum board-name length, and whether a rename changes the
  advertised name.
- The layout of `7dc56bfc` (power), whether boards expose `7dc5c19d`
  (units), and which boards expose the lights characteristics.
- The 1st-gen BRSP payload, the serial-pipe framing and the bootloader
  protocol are unmapped, the last two on purpose.

## Tools Used

- [x] Static analysis of the vendor Android app (final release 1.4.5)
- [x] Internet Archive copies of the vendor's support site and 2014 insert
- [ ] nRF Connect / LightBlue read of a real board (still to do)
- [ ] btsnoop capture of the vendor app on a board (still to do)

## References

- [Boosted: riding-mode insert for 1st-gen Dual and Dual+ (2014, archived PDF)](https://web.archive.org/web/20160616061842/http://boostedboards.com/wp-content/uploads/2014/12/Manual-Insert.pdf)
- [Boosted support: How to Update Your Board's Software (archived)](https://web.archive.org/web/20191115095759/https://support.boostedboards.com/hc/en-us/articles/115004591014-How-to-Update-Your-Board-s-Software-Required-for-Extended-Range-Battery-)
  is the source of the five-press pairing step.
- [Boosted support: The Boosted App (archived)](https://web.archive.org/web/20191216105010/https://support.boostedboards.com/hc/en-us/articles/115000910028-The-Boosted-App)
- [Boosted support: How to Install Your Boosted Beams (archived)](https://web.archive.org/web/20191216104420/https://support.boostedboards.com/hc/en-us/articles/360038377014-How-to-Install-Your-Boosted-Beams)
- [Forever Boosted FAQ](https://foreverboosted.co/faq) covers the owner
  community's notes on firmware, reading versions and the Hyper lockout.
- [Project Beambreak](https://beambreak.org/) covers remote BLE IDs,
  battery codes and known firmware versions.
- [axkrysl47/BoostedBreak](https://github.com/axkrysl47/BoostedBreak)
  covers the battery-ESC CAN protocol.
- [Tejas Bhakta: Reverse Engineering the Boosted Board Remote](https://tejasbhakta.com/boosted-board)
  covers the riding link.
- [johnathanchiu/boosted-project](https://github.com/johnathanchiu/boosted-project)
  is an ESP32 replication of board-remote pairing.
- [Reverse engineering the Boosted Board v1 (shwin.co)](https://shwin.co/blog/reverse-engineering-the-boosted-board-v1)
- [SharpX-Technologies/Coyote-App](https://github.com/SharpX-Technologies/Coyote-App)
  is an unrelated product's README that lists the BRSP UUIDs by role.
- [Boosted USA FAQ](https://boostedusa.com/pages/faq) explains who holds
  the leftover inventory today.

## Contributors

- Initial spec: static analysis of the vendor app, archived vendor support
  pages and the owner community's FAQ. No hardware was used.
