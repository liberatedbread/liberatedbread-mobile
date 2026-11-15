# WaterRower ComModule / SmartRow

> **Status**: Spec Available (capture/source-derived; untested on hardware here)
> **Protocol**: BLE FTMS and SmartRow ASCII telemetry
> **Manufacturer**: WaterRower
> **Manufacturer Status**: Active

## Overview

WaterRower has two distinct telemetry paths:

- **ComModule** attaches to an S4 Performance Monitor and exposes standard
  Bluetooth FTMS Rower Data.
- **SmartRow** is a separate power meter with a vendor ASCII protocol on service
  `00001234-0000-1000-8000-00805f9b34fb`.

The ComModule `f364…` extension is undecoded and does **not** belong to
SmartRow. The separate **LightRing BF** is an LED device, not a rowing telemetry
service.

SmartRow's V3.10 layouts are backed by a sanitized public capture: all 1,476
records pass the documented checksum and all 44 bridge tests passed. This
project did not use a physical WaterRower; capture consistency does not prove
measurement accuracy or other firmware compatibility.

## Setup and Pairing

No account or cloud is required. SmartRow advertisements carry the `SmartRow`
name and `0x1234` service. ComModule advertises standard FTMS `0x1826`, which is
shared with other fitness equipment and needs owner confirmation rather than
blind model matching.

No common factory-reset procedure is established. `start_session` is a workout
start/reset, not a hardware factory reset. The KEYLOCK transform is an
interoperability exchange, not meaningful authentication or owner provisioning.

## ComModule: standard FTMS

Subscribe to Rower Data `00002ad1-0000-1000-8000-00805f9b34fb` on FTMS
`00001826-0000-1000-8000-00805f9b34fb`. Read the standard Battery Level
`00002a19-0000-1000-8000-00805f9b34fb` when exposed.

Flags are uint16 LE. Fields appear in this order when present:

| Flag | Field | Encoding |
|---:|---|---|
| bit 0 **clear** | Stroke Rate and Stroke Count | uint8 × 0.5 strokes/min; uint16 LE count |
| bit 1 | Average Stroke Rate | uint8 × 0.5 strokes/min |
| bit 2 | Total Distance | uint24 LE metres |
| bit 3 / 4 | Instant / Average Pace | uint16 LE seconds per 500 m |
| bit 5 / 6 | Instant / Average Power | signed int16 LE watts |
| bit 7 | Resistance Level | uint8, unitless—not automatically a damper number |
| bit 8 | Total Energy / Energy per Hour / Energy per Minute | uint16 kcal, uint16 kcal/h, uint8 kcal/min |
| bit 9 | Heart Rate | uint8 bpm; workout telemetry, not medical validation |
| bit 10 | Metabolic Equivalent | uint8 × 0.1 MET |
| bit 11 / 12 | Elapsed / Remaining Time | uint16 LE seconds |

Bit 0 is **inverted More Data**: clear means Stroke Rate/Count are present and
the record is final; set means those fields are absent and more fragments
follow. Retain partial fields until finalization instead of substituting zero.
Energy sentinels `0xffff` / `0xff` mean unavailable.

An all-fields synthetic buffer uses flags `0x1ffe` and is 29 bytes, so it does
not fit one default-MTU notification. Real devices may fragment fields.

## SmartRow GATT and session

| Role | UUID |
|---|---|
| Service | `00001234-0000-1000-8000-00805f9b34fb` |
| Command/write | `00001235-0000-1000-8000-00805f9b34fb` |
| Telemetry/notify | `00001236-0000-1000-8000-00805f9b34fb` |

Commands are ASCII:

| Bytes | Purpose |
|---|---|
| `24 0d 56 40 0d` (`$\rV@\r`) | Initial start/reset; returns version. **Advanced:** preserve the current workout first |
| `24` (`$`) | Keepalive, approximately every two seconds on V3.10 |
| `2a` (`*`) | Request configuration after a V3 greeting |
| `0d 52 45 4d 4f 54 45 3e 0d` (`\rREMOTE>\r`) | Request remote/configuration text |
| `23` (`#`) | Request a KEYLOCK challenge after a V3 version reply |

Do not send these as generation-discovery probes. Match the device and service
first. No motor, resistance, workout-programming, calibration or firmware
command is documented.

### Record framing and checksum

Notifications are CR-delimited ASCII, but BLE fragments must be reassembled.
A telemetry record is **17 wire bytes**: 14 data characters, two checksum
characters, then CR.

```text
sum(raw_bytes[0:14]) & 0xff == int(raw_ascii[14:16], 16)
```

Validate before interpreting any field. Distance is five decimal digits at
characters 1–5 after transforming each byte as `(byte & 0x0f) | 0x30`. Ordinary
ASCII digits pass through unchanged.

### V3.10 fields

| Prefix | Interpretation |
|---|---|
| `a` | Elapsed `MMMSS`: minutes at 6–8, seconds at 9–10—not hours/minutes/seconds |
| `b` | Work per stroke at 6–10 / 10; stroke length at 11–13. Preserve raw because physical units remain unresolved |
| `c` | Instant power at 6–8 W; average power at 9–13 / 10 W |
| `d` | Stroke rate at 6–8 / 10 strokes/min; stroke count at 9–12 |
| `e` | Instant split: minutes at 6 plus seconds at 7–8; average split: minutes at 9 plus seconds at 10–11 |
| `f` | `!` at offset 11 means stopped; repeated `c`/`d`/`e` values are stale until a new stroke |
| `x`, `y`, `z` | Eight force points each at 6–13: `(ord(char) - 33) * 16`; concatenate for 24 points, with no calibrated unit claimed |

Examples from the sanitized capture:

```text
c@@@BH  0  349FD  -> instant 0 W, average 34.9 W
c@@@GB 45  35815  -> instant 45 W, average 35.8 W
d@@@BH266   3-0C  -> 26.6 strokes/min, 3 strokes
e@@@BG000337 w72  -> instant 0 s/500 m, average 217 s/500 m
a@@@BH00012   FE  -> elapsed 12 seconds
x@@PBE&(*,-.!!10  -> distance 25 m; force points 80, 112, 144, 176, 192, 208, 0, 0
```

The complete records above include their checksum characters; a decoder must
validate them before using the values.

### KEYLOCK

For a valid `KEYLOCK=<seed><checksum>` challenge, validate the same checksum,
parse the seed as big-endian hex, compute `seed * 17923 // 256`, format six
uppercase hex digits, discard the first two, and return the remaining four in
lowercase wrapped in CR.

Examples:

- `KEYLOCK=001A2B95` → `\r2810\r`
- `\rKEYLOCK=CBFF31C4\r` → `\rca63\r`

A bad checksum requests retry with `#`. This is not meaningful cryptographic
authentication.

## LightRing BF is separate

The LightRing BF uses service `e54b1234-67f5-479e-8711-b3b99198ce6c` and
control characteristic `e54b0003-67f5-479e-8711-b3b99198ce6c`, with local name
`LightRing BF`.

- Solid colour: `[00, green, red, blue]`; red is `00 00 ff 00`.
- Pixel frame: `[02, slot_le16, 156 green/red/blue bytes]`—52 triplets, 159
  bytes total.
- Select frame: `[03, slot, mode_flag, duration_le16]`. Exact loop/start
  semantics are unresolved.
- Native animation commands exist in the public implementation but remain
  experimental and are not declared as supported here.

Do not mistake this LED protocol for SmartRow telemetry or a generic ComModule
configuration API.

## Validation and remaining gaps

`scripts/test_waterrower_smartrow_spec.py` independently validates checksums,
capture-backed fields, distance/force decoding, keylock responses and malformed
records. Remaining gaps are other firmware, calibrated force/work/stroke-length
units, the ComModule `f364` extension, physical pairing/reset behavior and
LightRing animation semantics.

See `device-specs/devices/waterrower-smartrow.yaml` for the complete
machine-readable profiles and evidence boundaries.

## References

- [madooroy/smartrow-bridge (GPL-3.0)](https://github.com/madooroy/smartrow-bridge), pinned at `fdf634e60726208625df267741f26d1a796a2cd8`
- [inonoob/pirowflo](https://github.com/inonoob/pirowflo), pinned at `c4aab7a22b712101059ea34f3593d86296cdd839`
- [phbaer/waterrower-local-ble](https://github.com/phbaer/waterrower-local-ble), pinned at `43927584a4618c161b263a35008275d8a991754c`
- [WaterRower Bluetooth ComModule owner's manual](https://web.archive.org/web/20250109115057/https://media2.waterrower.com/service/manuals/WEB_ComModule_Instructions_Commodule-Manual.pdf)
- [WaterRower SmartRow user manual](https://web.archive.org/web/20250109142126id_/https://media2.waterrower.com/service/manuals/SmartRow-Manual.pdf)
