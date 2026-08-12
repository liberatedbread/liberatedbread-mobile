# Tongsheng TSDZ2 Mid-Drive Motor

> **Status**: Research
> **Protocol**: UART (serial, 9600 baud)
> **Manufacturer**: Tongsheng (TSDZ2 / TSDZ2B)
> **Manufacturer Status**: Active (no app, no radio; stock firmware supersedable)

## Overview

The TSDZ2 is a torque-sensing mid-drive conversion kit and the main DIY alternative to the
[Bafang BBS02](bafang-bbs02.md). Like the BBS02 it has **no radio and no app** — the
controller talks to the display over a plain TTL serial link on the main harness.

Unlike the BBS02, it is not a request/response configuration protocol. The TSDZ2 link is a
**continuous two-way telemetry stream**: the motor pushes status 8 times a second, the
display pushes control 15 times a second, and neither side waits for the other. There is no
"read the settings block" exchange — the display simply keeps asserting what it wants.

!!! success "Already liberated, twice over"
    The serial protocol is documented in full by the community, and open-source firmware
    (OSF) replaces the stock controller firmware outright — adding FOC commutation, a wider
    voltage range and configurable assist. For this device the interesting work is not
    recovering the protocol; it is giving a phone or hub a way onto that serial link.

## Hardware

| Property | Value |
|----------|-------|
| Variants | TSDZ2, TSDZ2B |
| Sensing | Torque sensor (not cadence-only) — the reason people pick it |
| Radio | **None** — UART only |
| Display bus | 9600 baud TTL, 6-pin Tongsheng connector |
| Stock displays | VLCD5, VLCD6, XH18 (shared protocol) |
| OSF-capable displays | Also SW102, DZ41, 850C, 860C |
| Wiring | Brown = motor TX (display RX), orange = motor RX (display TX) |

## Protocol Summary

### Serial parameters

| Setting | Value |
|---------|-------|
| Baud rate | **9600** (note: *not* the BBS02's 1200) |
| Framing | 8N1 |
| Checksum | 8-bit sum of all preceding bytes |
| Endianness | 16-bit values little-endian |

### Motor → display packet

**9 bytes, 8 times per second.**

| Offset | Length | Field | Notes |
|--------|--------|-------|-------|
| 0 | 1 | Start byte | always `0x43` |
| 1 | 1 | Battery level | see encoding below |
| 2 | 1 | Status flags | bits: low voltage, unknown, motor running, PAS status |
| 3 | 1 | Torque sensor tara | zero/reference value |
| 4 | 1 | Torque sensor value | current reading |
| 5 | 1 | Error code | `0x08` = undervoltage |
| 6 | 2 | Speed | 16-bit, low byte first |
| 8 | 1 | Checksum | 8-bit sum of bytes 0–7 |

**Battery level encoding**: `0x00` red blinking · `0x01`–`0x09` red through green ·
`0x0A` and above full green.

### Display → motor packet

**7 bytes, 15 times per second.**

| Offset | Length | Field | Notes |
|--------|--------|-------|-------|
| 0 | 1 | Start byte | always `0x59` |
| 1 | 1 | Control flags | bits: headlight, assist levels 2–4, assist off, 6 km/h walk mode, assist level 1, hidden level |
| 2 | 1 | Unused | |
| 3 | 1 | Wheel size | inches, range 6–29; default `0x1A` (26″) |
| 4 | 1 | Unknown | |
| 5 | 1 | Max speed | km/h, minimum `0x0E` (14); default `0x19` (25) |
| 6 | 1 | Checksum | 8-bit sum of bytes 0–5 |

!!! warning "The control packet *is* the write path"
    There is no separate configuration write. Wheel size and max speed are asserted in
    every display→motor packet, 15 times a second. Anything sitting on this bus that
    transmits is, by definition, setting them.

    Raising the max-speed byte is the derestriction path, and on a pedelec it can move the
    bike out of EAPC/pedelec classification — changing what licence, insurance and road
    access apply. Documented because it is your bike; a consumer exposing it should treat
    it as `advanced` and say so at the point of change.

### Verification

`reported` throughout — the packet layouts are documented by community work
(`hurzhurz/tsdz2`) and corroborated by multiple independent OSF forks, but nothing here has
been captured from a physical unit by us. Bytes 2 and 4 of the display packet are
undocumented even in the sources; treat them as unknown rather than assuming zero.

## Stock firmware vs OSF

Worth establishing before anyone captures anything: **which firmware is running changes the
protocol.** The tables above describe the stock Tongsheng firmware. Open-source firmware
adds fields and, on the 850C/860C/SW102 displays, uses a different and richer link. A
capture that disagrees with this page most likely means OSF is installed — check first.

## Device spec

[`device-specs/devices/tsdz2-tongsheng.yaml`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/device-specs/devices/tsdz2-tongsheng.yaml)
carries this protocol as a machine-readable `bus` spec (`protocol: uart`, `style: stream`).
Both packet shapes are catalogued with their `start_byte`, `length`, `rate_hz` and full
field tables, and the entities bind to decoded fields via `state_field`
(e.g. `motor_status.speed`) since there is no GATT characteristic to point at.

`display_control` is marked `writes: true` and `advanced` — correctly, because in stream
style a control packet writes by existing at all. The two undocumented display bytes are
recorded as `hypothesis` fields rather than silently omitted.

## Tools Used

- [ ] USB-TTL serial adapter (3.3 V) on the brown/orange harness lines
- [ ] Logic analyser or `socat` capture to verify checksums against live traffic
- [ ] ST-Link (STM8 flashing) if working with OSF rather than the stock firmware

## References

- [hurzhurz/tsdz2 — serial communication documentation](https://github.com/hurzhurz/tsdz2/blob/master/serial-communication.md)
- [hurzhurz/tsdz2 — information collection](https://github.com/hurzhurz/tsdz2)
- [OpenSourceEBike — TSDZ2 controller firmware](https://github.com/OpenSourceEBike/TongSheng_TSDZ2_motor_controller_firmware)
- [emmebrusa/TSDZ2-Smart-EBike-1 — OSF for VLCD5/VLCD6/XH18](https://github.com/emmebrusa/TSDZ2-Smart-EBike-1)
- [TSDZ2 wiki — communication protocol](https://github.com/OpenSource-EBike-firmware/TSDZ2_wiki/wiki/Communication-Protocol)

## Contributors

- Initial research — packet layouts transcribed from public community documentation; not
  yet verified against a physical unit.
