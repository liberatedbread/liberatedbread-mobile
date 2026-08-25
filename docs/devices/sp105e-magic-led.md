# SP105E Magic LED Pixel Controller

> **Status**: Complete (static analysis — not yet driven against hardware)
> **Protocol**: BLE
> **Manufacturer**: Sperll-era firmware family; sold under BTF-LIGHTING, ALITOVE, Super Bright LEDs and other brands
> **Manufacturer Status**: Unsupported

## Overview

The SP105E is a generic Bluetooth SPI pixel ("dream color") controller sold with
addressable LED strips under dozens of brand names. It is driven by the **Magic-LED**
app (`com.vengean.magicled`), and the good news is unusual for this catalogue: the app
is **fully local** — no account, no cloud service, no OTA mechanism, no analytics. The
only thing standing between you and permanent local control was the undocumented BLE
protocol, which is now recovered in full: command frame, complete opcode map, handshake,
status layout, and the 27-IC driver table.

The protocol was recovered by clean-room static analysis of Magic-LED v2.2.1. The byte
formats and opcodes the app sends are exact; what still needs a live capture is flagged
under [Open Questions](#open-questions).

## Hardware

| Property | Value |
|----------|-------|
| Model Number | SP105E (advertised BLE name is exactly `SP105E`) |
| Chipset | Unknown BLE module (HM-10-style serial-port profile; no vendor SDK fingerprints) |
| Radio | BLE 4.x |
| Output | SPI data for addressable pixel strips |
| Supported LED ICs | 27 drivers: SM16703, TM1804, UCS1903, WS2811, WS2801, SK6812 (+RGBW), LPD6803, LPD8806, APA102/APA105, TM1814/TM1914/TM1913, P9813, INK1003, DMX512, P943S/P9411-P9414, TX1812/TX1813, GS8206/GS8208, SK9822 |
| Power | DC 5–24 V (per retail listings) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `SP105E` (exact) |
| Passphrase protection | not_applicable |
| Confidence | medium (from app analysis; not yet run against hardware) |

Power the controller, scan for the exact advertised name `SP105E`, connect, enable
notifications on `0xFFE1`, run the handshake (below), then query status. There is no
account, no pairing PIN and no credential exchange.

**Factory reset**: there is no documented reset and nothing credential-like to clear —
the device bonds to nothing. The opcode table contains a defined-but-never-sent `clear`
command (`0x0F`) that is the likely reset-to-defaults, but its behaviour is unverified;
do not rely on it yet. Whether the strip configuration (IC type, RGB order, pixel
count) survives a power cycle is also unknown. The practical remedy for "won't connect"
is a power cycle: the controller holds a single BLE connection, and a nearby phone
still connected to it will block you.

**Rebinding to a new controller**: just connect from the new one — nothing ties the
device to an owner or network. Disconnect (or forget) the old phone first, since a
client that auto-reconnects will hold the single available link.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000ffe0-0000-1000-8000-00805f9b34fb` | SP105E Control Service | Serial-port profile |
| `0000ffe1-0000-1000-8000-00805f9b34fb` | Control | Commands (write) + replies (notify) |

### Command frame

Every command is exactly **5 bytes** written to `0xFFE1`. No length prefix, no checksum.

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Header `0x38` (ASCII `8`) |
| 1–3 | 3 | Parameters `p0..p2` (big-endian where multi-byte); unused slots are filler — the app sends random bytes avoiding `0x38`/`0x83`, `0x00` is fine |
| 4 | 1 | Opcode |

### Handshake

After connecting, send `check_device` with three arbitrary bytes `r0 r1 r2` (none of
them `0x38` or `0x83`):

```
38 r0 r1 r2 D5
```

The device replies within ~5 s with exactly 8 bytes `00 01 02 03 04 05 06 KEY` where:

```
KEY = ((r2 >> 5) & 0x07) | ((r0 << 1) & 0x53) | r1
```

Only after a correct reply will the vendor app send further commands. This is an
obfuscation-grade challenge, not encryption — the formula above is complete.

### Status reply

`get_info` returns an 8-byte notification; **any** 8-byte notification is parsed as
this block:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Power (1 = on, 0 = off) |
| 1 | 1 | Current mode (1–200 effect index; static/auto modes' report value unverified) |
| 2 | 1 | Speed (range unverified, commonly 1–31) |
| 3 | 1 | Brightness (range unverified, commonly 1–255) |
| 4 | 1 | IC type index (0–26) |
| 5 | 1 | RGB order index (0–5) |
| 6–7 | 2 | Pixel count, big-endian uint16 |

### Commands

Filler bytes shown as `00`.

| Command | Bytes | Description |
|---------|-------|-------------|
| Power toggle | `38 00 00 00 AA` | Toggles output — no discrete on/off exists; read status byte 0 first |
| Get status | `38 00 00 00 10` | Returns the 8-byte status block |
| Auto cycle | `38 00 00 00 06` | Cycle through effect modes automatically |
| Jump to mode | `38 MM 00 00 2C` | Dynamic effect 1–200 (wraps 200 → 1); modes are numeric, the app has no names |
| Static red / green / blue | `38 00 00 00 12` / `18` / `36` | Static presets |
| Static white / warm white | `38 00 00 00 3B` / `56` | Static presets |
| Solid color | `38 RR GG BB 1E` | Custom static RGB |
| Speed up / down | `38 00 00 00 03` / `09` | Relative steps — no absolute setter |
| Brightness up / down | `38 00 00 00 2A` / `28` | Relative steps — read status for the current value |
| Set pixel count | `38 HI LO 00 2D` | Big-endian uint16 |
| Set RGB order | `38 NN 00 00 3C` | Index 0–5 into [RGB, RBG, GRB, GBR, BRG, BGR] |
| Set IC type | `38 NN 00 00 1C` | Index 0–26 into the IC table (see Hardware) |

Defined but **never sent by this app version** (behaviour unverified): mode up `0x17`,
mode down `0x05`, remote pairing `0x1D`, clear `0x0F`.

### Timing

Pace commands at one per ~200 ms, retry a failed write once after 200 ms, and allow up
to 5 s for the handshake reply — that is what the vendor app does, and the controller
is a low-end MCU.

### Discovery

| Signal | Meaning |
|--------|---------|
| Local name exactly `SP105E` | This device — use this command set |
| Service `0000ffe0-…` present | SP105E **or** an SP107E/SP110E sibling — discriminate by name |

The SP107E/SP110E family ([spec](leds2rave4-lunchbox-led.md)) shares the `0xFFE0`
service but advertises different names and speaks a 4-byte opcode set with no `0x38`
header.

## Open Questions

- Speed/brightness accepted ranges (step to the limits and read status back).
- Whether IC type / RGB order / pixel count persist across power cycles.
- Behaviour of the four never-sent opcodes — `clear` (`0x0F`) is the probable factory
  reset.
- Whether device→app frames carry an `0x83` header (inferred from the app's filler
  avoidance; only 8-byte replies are actually parsed).
- What the status `mode` byte reports while a static or auto mode is active.

## Tools Used

- [x] APK static analysis (jadx) — Magic-LED v2.2.1, clean decompile, no native code
- [ ] HCI snoop of connect + command pass (pending)

## References

- [BTF-LIGHTING — SP105E Bluetooth SPI LED Controller](https://www.btf-lighting.com/products/sp105e-spi-led-controller)
- [Super Bright LEDs — Magic-LED Bluetooth Controller (SP105E)](https://www.superbrightleds.com/magic-led-bluetooth-controller-for-digital-rgb-led-strip-lights-sp105e)
- [Magic-LED on Google Play](https://play.google.com/store/apps/details?id=com.vengean.magicled)
- [SP107E/SP110E sibling family](leds2rave4-lunchbox-led.md) — same `0xFFE0` service, different opcode set
- [SP110E protocol gist](https://gist.github.com/mbullington/37957501a07ad065b67d4e8d39bfe012) — BLE-sniffed sibling

## Contributors

- Liberated Bread clean-room research — static-analysis recovery of the full command set (desk research only; live capture pending)
