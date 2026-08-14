# Bafang BBS02 Mid-Drive Motor

> **Status**: Research
> **Protocol**: UART (serial); BLE only via an aftermarket bridge display
> **Manufacturer**: Suzhou Bafang Electric Motor Science-Technology
> **Manufacturer Status**: Active (no official app or radio for this motor family)

## Overview

The BBS02 is Bafang's 36–48 V mid-drive conversion kit (250–750 W), sharing a controller
architecture and configuration protocol with the BBS01 and the BBSHD. The controller is
integrated into the motor housing and speaks a simple **1200-baud UART** protocol to the
display over the kit's main harness.

The important thing for OpenGreenIoT: **the BBS02 has no radio and no official app.**
There is no Bluetooth in the motor, and Bafang's own "Bafang Go"/BESST tooling targets the
newer CAN-bus M-series (M500/M510/M600), not the BBS family. Everything that talks to a
BBS02 does so over that UART bus. The app layer is therefore always something *someone
else* bolted on:

| Route | Transport | Notes |
|-------|-----------|-------|
| Bafang Config Tool (Stefan Penov) | USB programming cable → UART | Windows; the de-facto standard for years |
| [OpenBafangTool](https://github.com/andrey-pr/OpenBafangTool) | USB cable → UART (also CAN) | MIT-licensed, open source, supports BBS01/BBS02/BBSHD |
| EggRider V2 display | BLE → UART bridge | Phone app (`com.eggbikes.EggRider`); read/write params with no cable |
| [bbs-fw](https://github.com/danielnilsson9/bbs-fw) | replacement firmware | Open-source firmware for the BBS02/BBSHD controller itself |

!!! success "This protocol is already open"
    Unlike most targets in this registry, the BBS02's configuration protocol is **fully
    documented in public, MIT-licensed community work** — there is no proprietary blob to
    liberate. The opcode tables below are transcribed from that work. The genuine gap is
    that reaching the bus still means a USB cable or a proprietary BLE display; a small
    open BLE↔UART bridge would close it. See the target sheet for that scope.

## Hardware

| Property | Value |
|----------|-------|
| Family | BBS01 / BBS01B, BBS02 / BBS02B, BBSHD (shared protocol) |
| Nominal voltage | 36 V or 48 V (BBSHD 48–52 V) |
| Rated power | 250 W / 350 W / 500 W / 750 W |
| Controller | Integrated in the motor housing |
| Radio | **None** — UART only |
| Display bus | 1200 baud serial, shared harness (display, throttle, brake cutoffs) |

## Protocol Summary

### Serial parameters

| Setting | Value |
|---------|-------|
| Baud rate | **1200** |
| Framing | 8N1 (standard) |
| Bus | Shared display/controller line on the main harness |

### Packet formats

**Read request** — most reads are bare code bytes (`0x11 0x52`, `0x11 0x53`, `0x11 0x54`)
with no length or checksum. The device-info/connect read is the exception: it carries two
payload bytes and a checksum, `0x11 0x51 0x04 0xB0 0x05`, where `0x05` is
`(0x51 + 0x04 + 0xB0) mod 256`. Do not assume every read is bare.

**Read response**:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Code — identifies which request this answers |
| 1 | 1 | Length — number of data bytes |
| 2 | n | Data |
| 2+n | 1 | Checksum — sum of all other bytes, mod 256 |

**Write request**:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 2 | Code — two-byte opcode |
| 2 | 1 | Length — number of data bytes |
| 3 | n | Data |
| 3+n | 1 | Checksum — sum of the **second** code byte, the length byte and all data bytes, mod 256 |

**Write response**:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Code |
| 1 | 1 | Error parameter index, or the length if no error |
| 2 | 1 | Checksum — sum of code and data, mod 256 |

!!! note "The two checksum rules differ"
    Read responses sum *every* preceding byte. Write requests skip the first code byte.
    This asymmetry is the most common source of rejected writes.

### Read commands

| Code | Returns | Format |
|------|---------|--------|
| `0x11 0x50` | Firmware version | ASCII (e.g. `CRX10B4812E010026.3`) |
| `0x11 0x51 0x04 0xB0 0x05` | Complete device info | 16 bytes — manufacturer (4), model (4), hardware version (2), firmware version (4), voltage (1), max current (1) |
| `0x11 0x52` | Basic parameters | 24 bytes — see below |
| `0x11 0x53` | Pedal assist parameters | 11 bytes — see below |
| `0x11 0x54` | Throttle parameters | 6 bytes — see below |
| `0x14 0x12` | Power specification code | ASCII (e.g. `MAX_DS48V250W`) |
| `0x14 0x13` | System code | ASCII (e.g. `MAX01_V2.2_DS`) |
| `0x14 0x14` | Serial number | ASCII (e.g. `201608080001`) |
| `0x14 0x15` | Error codes | Byte array; empty when no faults |
| `0x14 0x16` | Model data | ASCII (e.g. `20160808`) |

### Write commands

Each write takes the same payload layout as the matching read returns.

| Code | Writes | Payload | Advanced |
|------|--------|---------|----------|
| `0x16 0x52` | Basic parameters | 24 bytes | **Yes** |
| `0x16 0x53` | Pedal assist parameters | 11 bytes | **Yes** |
| `0x16 0x54` | Throttle parameters | 6 bytes | **Yes** |
| `0x17 0x01` | Serial number | ASCII | **Yes** |

!!! warning "Advanced — these retune a vehicle you ride"
    All four writes should carry `advanced: true` in any spec that declares them: available,
    behind a deliberate action, with the reason shown at that moment. Here is what each one
    actually costs you if it goes wrong:

    - **Current limits are thermal limits.** Raising max current beyond the motor's rating
      is the classic way to cook a BBS02's nylon primary gear or the controller MOSFETs.
      The motor will not stop you.
    - **Low-voltage cutoff protects the battery.** Setting it below the pack's real cutoff
      pushes cells into over-discharge.
    - **Throttle and speed-limit settings change legal class.** Enabling throttle-from-zero
      or lifting the speed limit can move the bike out of pedelec/EAPC classification —
      changing what licence, insurance and road access apply.
    - **The serial number write is effectively irreversible** and can break warranty and
      dealer-tool workflows. It has real uses — restoring identity after a controller swap
      is a normal repair-bench job — so it is documented like anything else; just know that
      there is no undo.

    **Read the block first and keep a copy.** The write payload is the whole block, so a
    partial edit means writing back fields you did not intend to change — and an archived
    block is your restore path for every item above.

### Basic parameter block (`0x52`, 24 bytes)

Offsets are into the 24-byte data payload (i.e. the frame less its `0x52` code, length byte
and trailing checksum — the full frame is 27 bytes).

| Offset | Length | Field | Encoding |
|--------|--------|-------|----------|
| 0 | 1 | Low battery protect | volts |
| 1 | 1 | Current limit | amps |
| 2 | 10 | Assist 0–9 **current** limit | percent, one byte per level |
| 12 | 10 | Assist 0–9 **speed** limit | percent, one byte per level |
| 22 | 1 | Wheel diameter | code, `0x1F`–`0x3C` for 16″–30″; `0x37` = 700C |
| 23 | 1 | Speedmeter model | bits 1–2: `00` external, `01` internal, `10` motor phase |

!!! warning "The assist limits are two arrays, not interleaved pairs"
    Current limits for levels 0–9 occupy ten consecutive bytes, *then* speed limits for
    levels 0–9 occupy the next ten. They are **not** ten `(current, speed)` pairs. Parsing
    them as pairs yields plausible-looking nonsense — every value lands on the wrong level
    and half of them are read as the wrong quantity. Corroborated across two independent
    implementations.

### Pedal assist parameter block (`0x53`, 11 bytes)

| Offset | Field | Encoding |
|--------|-------|----------|
| 0 | Pedal sensor type | `0x00` none, `0x01` DH-12, `0x02` BB-32, `0x03` double-signal-24 |
| 1 | Designated assist | `0x00`–`0x09`, or `0xFF` = follow display |
| 2 | Speed limit | `0x0F`–`0x28` km/h, or `0xFF` = follow display |
| 3 | Start current | percent, `0x00`–`0x64` |
| 4 | Slow-start mode | `0x01`–`0x08` |
| 5 | Startup degree | pedal signal count before assist engages |
| 6 | Work mode | `0x0A`–`0x50` (angular speed × 10) |
| 7 | Time of stop | value × 10 ms |
| 8 | Current decay | `0x01`–`0x08` |
| 9 | Stop decay | value × 10 ms |
| 10 | Keep current | percent |

### Throttle parameter block (`0x54`, 6 bytes)

| Offset | Field | Encoding |
|--------|-------|----------|
| 0 | Start voltage | value × 100 mV |
| 1 | End voltage | value × 100 mV |
| 2 | Mode | `0x00` speed, `0x01` current |
| 3 | Designated assist | `0x00`–`0x09`, or `0xFF` = follow display |
| 4 | Speed limit | `0x0F`–`0x28` km/h, or `0xFF` = follow display |
| 5 | Start current | percent |

!!! warning "Verification: `reported`, with one known ambiguity"
    Block sizes, field order and the encodings above are corroborated across three
    independent implementations (OpenBafangTool and two `bafang-python` forks), so they are
    `reported` — well attested, but not `confirmed`, because nothing here has been read back
    from a physical unit by us.

    **The write length byte is genuinely ambiguous.** Sources give `0x16 0x52 0x24` for the
    basic-block write and `0x16 0x53 0x11` for the pedal block, yet the corresponding read
    responses carry lengths `0x18` (24) and `0x0B` (11). `0x24` and `0x11` are exactly 24
    and 11 written as if decimal were hex, which looks like a documentation slip
    propagated between forks — but it could equally be a real protocol quirk where writes
    use a different length convention. Capture a vendor-tool write before trusting either
    value. Nothing else in this doc depends on it.

## Device spec

[`device-specs/devices/bafang-bbs02.yaml`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/device-specs/devices/bafang-bbs02.yaml)
carries this protocol as a machine-readable `bus` spec (`protocol: uart`,
`style: request_response`), with every read and write above catalogued, the field tables
encoded as `fields` entries, and the four writes flagged `advanced`.

The assist-limit trap is encoded rather than merely described: `assist_current_limit` and
`assist_speed_limit` are two `array_len: 10` fields at offsets 2 and 12, which is
structurally unable to be read as ten interleaved pairs.

The write length byte is the one thing the spec deliberately does **not** assert — see the
ambiguity note above. The write messages carry their `16 5x` code and stop there.

## Related mid-drives

The other common DIY mid-drive is the **Tongsheng TSDZ2**, and it is worth knowing it is a
different bus, not a variant of this one: 9600 baud (not 1200), packets starting `0x43`
motor→display and `0x59` display→motor, an 8-bit sum checksum, and a continuous telemetry
stream (8 frames/second up, 15 down) rather than the request/response exchange used here.
Its protocol is documented in full by the community, and open-source firmware already
replaces the stock firmware outright. Tracked as `tsdz2-tongsheng` in `targets.csv`.

## Tools Used

- [ ] Bafang USB programming cable (UART, ~1200 baud) + USB isolator
- [ ] [OpenBafangTool](https://github.com/andrey-pr/OpenBafangTool) — read/write over UART
- [ ] Serial capture (e.g. `socat`/logic analyser) to verify checksums against live traffic
- [ ] nRF Connect — only if profiling an EggRider or other BLE bridge

## References

- [OpenBafangTool — UART protocol docs (MIT)](https://github.com/andrey-pr/OpenBafangTool/blob/master/docs/Bafang%20UART%20protocol.md)
- [OpenBafangTool — UART motor API (MIT)](https://github.com/andrey-pr/OpenBafangTool/blob/master/docs/Bafang%20UART%20motor%20API.md)
- [philippsandhaus/bafang-python — protocol + block layouts](https://github.com/philippsandhaus/bafang-python)
- [hliebscher/bafang-python — independent corroboration of the block layouts](https://github.com/hliebscher/bafang-python)
- [Endless Sphere — Bafang communication protocol (UART)](https://endless-sphere.com/sphere/threads/bafang-communication-protocol-uart.74692/)
- [bbs-fw — open-source BBS02/BBSHD firmware (danielnilsson9)](https://github.com/danielnilsson9/bbs-fw)
- [Endless Sphere — protocol specs for Bafang BBS02 mid-drive](https://endless-sphere.com/sphere/threads/protocol-specs-for-bafang-bbs02-mid-drive.60591/)
- [EggRider V2 — Bluetooth display for BBS01/BBS02/BBSHD](https://shop.eggrider.com/eggrider-v2)
- [EggRider mobile app (Google Play)](https://play.google.com/store/apps/details?id=com.eggbikes.EggRider)
- [EggRider user manual](https://manual.eggrider.com/mobile_app/overview/)

## Contributors

- Initial research — opcode tables and packet formats transcribed from public
  MIT-licensed community documentation; not yet verified against a physical unit.
