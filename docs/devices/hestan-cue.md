# Hestan Cue Smart Cooking System

> **Status**: Spec Available
> **Protocol**: BLE
> **Manufacturer**: Hestan Smart Cooking
> **Manufacturer Status**: Abandoned (app retired 2025-07-21)

## Overview

Hestan Cue is a guided-cooking system with four kinds of part: a portable
induction burner, pans and pots with a Bluetooth "capsule" in the handle, a
later clip-on Smart Probe, and a phone app. Each piece of hardware is its own
BLE peripheral, and the phone talks to each one directly. There is no hub. The
vendor cloud held accounts, recipes and firmware. The control paths themselves
are local.

The vendor retired the app on **2025-07-21**. Its support site says the burner
still works as an ordinary induction hob from its own touch controls, and that
every "smart" function ended with the app. The smart functions are
temperature-controlled cooking and guided recipes. This spec is the local BLE
protocol the app spoke, so that the cookware can be read again and the burner
driven again.

Two findings from the app shape everything below:

- **The burner closes the temperature loop, not the phone.** The app routes
  one piece of cookware to the burner, then writes a target in °C and six
  controller gains. The burner takes readings from that cookware and holds
  the target itself. It relays each reading back to the app as an event.
- **The burner does not let an app heat until a person confirms at the
  burner.** After the app asks for control, someone has to press the
  burner's power button and then its next button. This spec declares nothing
  that skips that step.

**In scope:** the Cue induction burner, and the pans, pots and Smart Probe
that carry the handle service `0000fa81-8a11-4222-9610-53f79479ca03`.

**Out of scope:** the built-in and Wi-Fi cooktops of other brands that the
same app drove, the smart-oven stub, every cloud API, and firmware image
transfer.

Everything here was read out of the vendor's Android app. None of it has been
run against hardware, so every protocol fact is `reported`.

!!! warning "This drives a 1600 W induction burner"
    Cue's own guidance is that its pans are safe empty to about 400 °F
    (204 °C) and should never exceed 450 °F (232 °C) with food in them. The
    app's Control Mode allowed up to 260 °C (500 °F). The vendor also says
    that an unattended stainless pan at full power can pass 750 °F before
    the burner's cut-out trips. Stay at the burner, keep to the vendor's
    limits, and finish with `disable_heating`.

    **Start read-only.** The cookware broadcasts its temperature in its
    advertisements. A thermometer client needs no connection, no write and
    no burner.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Burner: **41000** (US, 110–120 V 60 Hz, up to 1600 W) and **41004–41009** (240 V 50 Hz regions), per the vendor. The app also knows a 220 V partner build and a 100 V build. Cookware: 11-inch fry pan, 5.5 qt chef's pot, 3.5 qt pot and 11-inch non-stick fry pan, in first and second generations. Smart Probe: model **417** |
| Chipset | Not identified. The Nordic legacy and Secure DFU stacks the app uses suggest Nordic nRF5-series SoCs (hypothesis) |
| Radio | BLE 4.x (the vendor asks for a Bluetooth 4.0 LE phone). The FCC test report for the probe lists 2402–2480 MHz GFSK |
| Power | Burner: mains, ungrounded plug. Pan and pot: one AAA cell in the handle end cap (a quarter-turn back switches the capsule off). Probe: one CR2450 |
| FCC ID | Smart Probe: **2AYY4-41701** (Hestan Smart Cooking Inc., granted 2021-04-14). No grant was found for the burner or the pan and pot capsules under Hestan's grantee code |
| Bluetooth company ID | `0x03F1` (1009), registered to Hestan Smart Cooking Inc. |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No provisioning. There is no account, no Wi-Fi and no bond on the BLE path |
| Method | `ble_direct` (primary). The vendor's `cloud_account` flow is historical |
| Setup AP / advertised name | Local name: 8 characters of base64 encoding the device's address and type (see below). Manufacturer data is under company ID `0x03F1` |
| Passphrase protection | not_applicable |
| Confidence | low (from the app alone; never replayed) |

**One caveat can no longer be fixed.** The vendor says a factory-fresh burner
and cookware needed a firmware update from the app before they would cook, or
even turn on. The firmware came from the retired cloud, and the app ships no
images. A unit that was never updated may be stuck. Nobody has checked what
factory firmware answers over BLE.

To drive the burner:

1. Fit a fresh AAA cell in the pan handle and screw the end cap fully home. For
   the probe, fit a CR2450. Plug the burner in, and centre the pan on it.
2. Connect to the burner. Read the firmware version from
   `00001537-1212-efde-1523-785feabcd123` (or take it from a type-3
   advertisement). The app sends no command until it has a version.
3. Enable indications on `00001546-6209-4984-454e-f27d42fb55e3` and
   notifications on `00001545-6209-4984-454e-f27d42fb55e3`. Read `00001545`,
   `00001542` and `00001543`.
4. If `00001543` reports any mode but 4, turn the next-button light off and
   write mode 4 (`disable_heating`). The app always does this first.
5. If `00001542` does not hold the pan's address (least-significant byte
   first), write it with `route_cookware` and read it back.
6. Send `ask_for_app_control` (opcode `0x08` on
   `00001547-6209-4984-454e-f27d42fb55e3`).
7. **At the burner:** press the power button when event `0x6013` arrives, then
   the next button when `0x6014` arrives. Event `0x6015` means control is
   granted, and byte 1 of `00001545` then reads 3.
8. Write `set_target_temperature` (or `set_power_position`), then read
   `00001543` back.
9. To stop, turn the next-button light off, then send `disable_heating`.

**Factory reset**: none is documented. The only client-visible state is the
cookware ID the burner last had routed to it, and the next client overwrites
that. Unplugging the burner clears an overheat lock-out, according to the
vendor. Turning the handle's end cap a quarter-turn back and then tightening
it again power-cycles a pan capsule.

**Rebinding**: nothing binds the burner or the cookware to a phone or an
account. A new client connects, routes its cookware and asks for control. If
a phone bonded during an old firmware update, forget the device in that
phone's Bluetooth settings.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `optional` (only the app's legacy firmware-update path bonds) |
| PIN source | not applicable |
| One central at a time | Unknown |
| One bond at a time | Unknown |
| Confidence | medium (the app's product table and the vendor's support articles agree) |

The app treats the Cue burner and all Cue cookware as unpaired devices. It
connects, discovers services and talks with no bond. The vendor told owners
not to pair Cue devices from the phone's own Bluetooth settings.

There is one exception. Before a firmware update of a burner build or a
first-generation pan (both use Nordic's legacy DFU), the app asks the phone
to bond. The vendor's firmware article says to accept that prompt.

**Entering pairing mode**: nothing to enter. The burner advertises whenever
it is plugged in. The cookware advertises while its end cap is tight and its
battery is live.

**Unpairing**: only relevant after a legacy firmware update. Forget the device
in the phone's settings.

**Recovery**: close the vendor app if it is still installed. Turn Bluetooth off
on other phones and tablets, because the vendor says they can hold an old
connection. On Android, turn location services on. The vendor also documents
an OS pair-then-unpair workaround for phones that never see the devices.

## Protocol Summary

All multi-byte values are little-endian. Temperatures, gains and power
positions are IEEE 754 **binary32 floats**. The schema has no float type yet,
so the spec carries a float that a command writes as a `uint32` bit pattern
(for example, 200.0 °C is `0x43480000`, sent as `00 00 48 43`).

### Advertisements (read-only path)

The local name is 8 base64 characters. They decode to 6 bytes: the device
address, least-significant byte first. The top two bits of the last byte are
replaced by the device type: `00` pan, `01` pot, `10` burner. OR `0xC0` back
in to get the address. For example, `q4lnRSOB` is a burner at
`C1:23:45:67:89:AB` (an invented address).

Manufacturer data sits under company ID `0x03F1`. Offsets below count from
the first byte after the company ID:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 4 | Unknown u32 (the app discards it) |
| 4 | 1 | Frame counter |
| 5 | 1 | Frame type: 1 first-generation cookware, 2 second-generation cookware or probe, 3 burner |

Frame type 2 (second-generation cookware and Smart Probe):

| Offset | Length | Description |
|--------|--------|-------------|
| 6 | 1 | Firmware major |
| 7 | 1 | Firmware minor |
| 8 | 2 | Product ID (8 fry pan, 9 chef's pot, 10 3.5 qt pot, 13 Smart Probe, 18 non-stick pan) |
| 10 | 1 | Battery, raw (scale unknown) |
| 11 | 4 | **Temperature, float32, °C** |
| 15 | 1 | Cold junction, raw |
| 16 | 1 | Thermocouple status: 0 ok, 1 open, 2 too high, 3 too low, 4 not initialised, 5 computation error |

Frame type 1 (first-generation cookware) carries battery at 6, cold junction
at 7, two floats at 8 and 12 (the app uses the one at 12), and a fault byte at
19. Frame type 3 (burner) carries firmware major and minor at 6–7 and the
product ID at 8–9. The product IDs are 32 (US), 47 (220 V), 48 (220 V partner
build) and 96 (100 V).

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00001541-6209-4984-454e-f27d42fb55e3` | Burner control | Burner only. Every write goes here |
| `00001542-6209-4984-454e-f27d42fb55e3` | Cookware route | read/write, 20 bytes: request ID, the cookware's 6-byte ID, 12 zero bytes |
| `00001543-6209-4984-454e-f27d42fb55e3` | Burner mode | read/write, 36 bytes (below) |
| `00001545-6209-4984-454e-f27d42fb55e3` | Burner status | read/notify, 20 bytes. The first 8 bytes are one code each |
| `00001546-6209-4984-454e-f27d42fb55e3` | Burner events | indicate, 20 bytes: request ID, event code, body. Must be enabled |
| `00001547-6209-4984-454e-f27d42fb55e3` | Burner command | write, 3 bytes: request ID and an opcode |
| `0000fa81-8a11-4222-9610-53f79479ca03` | Cookware handle / probe | Pan, pot and (per the app) probe |
| `0000fa83-8a11-4222-9610-53f79479ca03` | Thermometer frame | 20 bytes (below) |
| `0000fa84-8a11-4222-9610-53f79479ca03` | Handle info | read, 6 bytes, meaning unknown. The app only length-checks it |
| `0000fa85-8a11-4222-9610-53f79479ca03` | Handle events | The app enables indications and parses nothing from it |
| `00001530-1212-efde-1523-785feabcd123` | Nordic legacy DFU | The stock DFU characteristics, not declared. Two vendor additions follow |
| `00001535-1212-efde-1523-785feabcd123` | Device identity | read, 4 bytes: u16 device type, u16 revision |
| `00001537-1212-efde-1523-785feabcd123` | Firmware version | read, u16. Needed before any `00001547` command |

Every write starts with a 16-bit request ID. The app draws them from one
counter for all devices, 1 to 32767, then wraps to 0.

### Commands

#### Burner mode (`00001543`)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | Request ID |
| 2 | 1 | Mode: 0 manual (the user is at the burner), 1 hold temperature, 2 fixed power position, 3 off, 4 disabled |
| 3 | 4 | Target, float32: °C in mode 1, fraction of full power in mode 2, otherwise 0 |
| 7 | 24 | Six float32 controller gains (mode 1), otherwise zeros |
| 31 | 1 | Flag, always `01` from the app |
| 32 | 4 | Timeout, u32 seconds |

What the app sent:

| Command | Mode | Target | Gains | Timeout |
|---|---|---|---|---|
| `set_target_temperature` | 1 | 37–260 °C, 1 °C steps | the app's fallback set 0.008, 0.006, 0.06 (twice) | 86400 Control Mode, 3600 recipe hold |
| `set_power_position` | 2 | 5 % idle, or level 1–10 = 10–100 % | zeros | 86400 Power tab, 9000 idle |
| `disable_heating` | 4 | 0 | zeros | 0 |

For example, 200 °C for one hour with request ID 8:

```
08 00 01 00 00 48 43 6f 12 03 3c a6 9b c4 3b 8f c2 75 3d
6f 12 03 3c a6 9b c4 3b 8f c2 75 3d 01 10 0e 00 00
```

A variant that takes caller-supplied gains is declared **advanced**. Wrong
gains can drive a pan far past its target.

#### Burner commands (`00001547`)

| Opcode | Meaning | Status in the spec |
|---|---|---|
| `0x02` / `0x03` / `0x04` | Next-button light on / off / blinking | ordinary (`set_next_button_light`) |
| `0x08` | Ask for app control. Starts the two-touch confirmation | ordinary: it only asks |
| `0x05` | Declares the app in control. Never sent by the app | **advanced**: it may bypass the confirmation |
| `0x06` | App lockout. Never sent by the app | **advanced** |
| `0x07` | Clear status. Never sent by the app | **advanced**: it may clear a latched fault |

#### Status (`00001545`, bytes 0–7)

| Byte | Meaning |
|---|---|
| 0 | App control permitted: 0 yes, 1 no |
| 1 | App control: 0 none, 1 waiting for power button, 2 waiting for next button, 3 app has control |
| 2 | Line voltage: 0 ok, 1 low, 2 high |
| 3 | Power transistor temperature: 0 normal, 1 power limited, 2 over temperature, 3 thermistor fault |
| 4 | Glass temperature: 0 normal, 1–2 reducing power, 3 over temperature, 4–5 thermistor fault |
| 5 | Power limit: 0 none, 1 one step down, 2 fixed cap, 3 intermittent, 4 no power |
| 6 | Cookware: 0 present, 1 not detected, 2 timed out |
| 7 | Cookware sensor: 0 missing, 1 ok, 2 corrupt, 3 open, 4 high, 5 low, 6 uninitialised, 7 computation error, 8–9 usable but high or low |

#### Events (`00001546`)

| Code | Meaning | Body (offsets from byte 0) |
|---|---|---|
| `0x7001` | Heartbeat | 4: float32 counter |
| `0x7002` | Power-stage telemetry | 4: current, 8: line voltage, 12: energy (float32 each); 16: pan-detect pulses; 17: glass temperature; 18: s16 power-transistor temperature |
| `0x7003` | Burner telemetry | 4: float32 position (fraction); 8: controller temperature |
| `0x7004` | Routed cookware identity | 4: device type, 6: revision, 8: software version (u16 each) |
| `0x7005` | Routed cookware reading | 4–7: counter, version, battery, cold junction; 8 and 12: float32 °C (12 is the one used); 16–17: sensor slots; 18–19: faults |
| `0x6008` | Status change | 4: counter; 6, 8, 10: status codes (u16); 12: u32 action (bit 0 burner off, bit 1 history overflow) |
| `0x6013`–`0x6016` | App control: press power, press next, granted, revoked | none |
| `0x600a` | The user took control at the burner | none. The app stops driving |
| `0x600e` / `0x600f` / `0x6010` | No cookware / cookware back / cookware timed out | none |
| `0x5009`, `0x500f`–`0x5012` | Over temperature, handshake needed or rejected, decrypt failures | none. The app stops the cook |

The full event and status-code tables are in the spec.

#### Thermometer frame (`0000fa83`, 20 bytes)

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Frame version |
| 1 | 1 | Battery, raw |
| 2 | 1 | Frame counter |
| 3 | 1 | Cold junction, raw |
| 4 | 4 | u32 timestamp (unit unknown) |
| 8 | 4 | float32 °C (logged only) |
| 12 | 4 | **float32 °C, cookware base temperature** (-999.0 means no reading) |
| 16 | 2 | Sensor slots |
| 18 | 1 | Fault for the base reading |
| 19 | 1 | Other fault |

## Troubleshooting

- **The burner ignores every command.** The vendor app never sends a
  command before it has the firmware version, and whether the burner itself
  requires that is not established. Read `00001537` first. If the burner never took the app's
  first firmware update, it may not run at all, and the image source is gone.
- **A setpoint is written but nothing heats.** Nobody finished the two-touch
  confirmation, the burner was not in mode 4 when control was requested, or
  the cookware is missing or not induction-compatible. It may also be in an
  overheat state. Let it cool, then unplug it and plug it back in.
- **The burner switches itself off mid-cook.** The controls are capacitive, and
  the vendor says a pan slid over them, or clothing near them, can press them.
  Turn the burner so the controls sit to the side.
- **Direct `0000fa83` frames never arrive.** The app enables indications only on
  `0000fa85`. It takes most readings from advertisements, or relayed by the
  burner as event `0x7005`. Use those.
- **The first three bytes of a reading look scrambled.** The app's two parsers
  disagree on their order. The direct frame reads version, battery, counter,
  and the burner relay reads counter, version, battery. The temperature
  offsets agree.
- **Status bytes 5 and 6 look swapped.** The app's built-in mock burner writes
  them in the opposite order to its real parser. The spec follows the parser.

## Tools Used

- [x] jadx over the vendor's Android app (Hestan Cue 1.5.x), including
  bad-code output and the instruction dump for the two methods that did not
  decompile
- [x] The vendor's support portal, and the FCC exhibits for 2AYY4-41701
- [x] The Bluetooth SIG company-identifier registry
- [ ] nRF Connect or an HCI snoop against a real burner and pan: **still
  needed**

## References

- [Hestan Cue Smart Probe quick start guide (FCC exhibit, PDF)](https://fccid.co/api/files/s1/2ayy4_41701_usersmanual_5205822_9a3cbbb602.pdf)
- [Hestan Cue Smart Probe safety instructions (FCC exhibit, PDF)](https://fccid.co/api/files/s1/2ayy4_41701_usersmanual_5205823_55bc75cbf9.pdf)
- [FCC ID 2AYY4-41701 (Hestan Cue Smart Probe)](https://fccid.co/fcc/2AYY4-41701)
- [Hestan Cue support: What is happening to the Hestan Cue app?](https://support.hestancue.com/en/support/solutions/articles/19000166286)
- [Hestan Cue support: Using the cooktop and cookware after the sunset](https://support.hestancue.com/en/support/solutions/articles/19000166287)
- [Hestan Cue support: Burner manual (offline) mode](https://support.hestancue.com/en/support/solutions/articles/19000061944)
- [Hestan Cue support: What is Control Mode?](https://support.hestancue.com/en/support/solutions/articles/19000054374)
- [Hestan Cue support: Power/voltage requirements](https://support.hestancue.com/en/support/solutions/articles/19000044461)
- [Hestan Cue support: Updating burner and cookware firmware](https://support.hestancue.com/en/support/solutions/articles/19000074350)
- [Hestan Cue support: Overheating error](https://support.hestancue.com/en/support/solutions/articles/19000086778)
- [Hestan Cue support: Cookware temperature limits](https://support.hestancue.com/en/support/solutions/articles/19000126757)
- [Hestan Cue support: Smart Probe temperature range](https://support.hestancue.com/en/support/solutions/articles/19000124628)
- [Hestan Cue support: Turning Cue cookware off](https://support.hestancue.com/en/support/solutions/articles/19000091230)
- [Hestan Cue support: Can't pair devices with the app](https://support.hestancue.com/en/support/solutions/articles/19000061597)
- [Hestan Cue on Google Play (archived 2024-07-20)](https://web.archive.org/web/20240720010437/https://play.google.com/store/apps/details?id=com.hestan.cue)
- [Firmware update stacks](../protocols/firmware-update.md)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)

## Contributors

- Claude Code agent: spec written from static analysis of the vendor app and the vendor's support site (desk research; no hardware)
