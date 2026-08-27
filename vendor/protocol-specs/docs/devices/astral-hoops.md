# Astral Hoops Atomic V (AF Series)

> **Status**: In Progress
> **Protocol**: BLE
> **Manufacturer**: Astral Hoops
> **Manufacturer Status**: Active

## Overview

The [Astral Hoops](https://astralhoops.com/) Atomic V line — LED hula hoops, wands and fans —
are programmable flow props driven by the vendor's **Astral** app (`com.astral.astral`). The
props speak a clean ASCII protocol over a standard transparent-UART BLE module, need no
account and no cloud, and even their firmware updates are public downloads — an unusually
friendly target for local control. The full machine-readable protocol is in
[`device-specs/devices/astral-hoops.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/astral-hoops.yaml).

Everything the app does works locally: mode and color control, per-prop settings, custom
POV pattern upload, and firmware OTA all run over the BLE connection. The app's only network
use is fetching firmware images and pattern packs from public HTTPS URLs.

## Hardware

| Property | Value |
|----------|-------|
| Models | Atomic V Hoop / Wand / Fan (AF series) |
| MCU | Microchip/Atmel SAM D21 (ARM Cortex-M0+) |
| Radio | BLE via Microchip/ISSC transparent-UART module |
| Firmware | Public: `a5.ver` = 5.2.5 (beta 5.3.0), raw flash image `af5.bin` |
| FCC ID | Unknown |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised name | `Atomic` + 5-character unit ID (`AtomicNNNNN`) |
| Passphrase protection | not_applicable |
| Confidence | medium (from app analysis; not yet exercised against hardware here) |

Power the prop on, scan for the `Atomic` name prefix, and connect from inside your app —
there is no pairing, PIN, or account. After connecting, enable notifications on the RX
characteristic and walk the settings query chain (`#GS`, `#GT`, `#GD`, `#GA`, `#GO`, `#GE`,
`#GL`, `#GN`) to learn the prop's configuration.

**Factory reset**: there is no physical reset procedure known; resets are BLE commands.
`#WIPE` clears your customizations (the prop answers `OK`); `#FORMAT` reformats pattern
storage, after which the factory patterns must be re-uploaded through the normal image
upload flow. Neither affects the BLE identity or the unit ID.

**Rebinding to a new controller**: just connect from the new phone — nothing binds the prop
to a controller. The prop holds one BLE connection at a time, so disconnect (or power-cycle)
the old phone first; a phone that keeps auto-reconnecting will hold the link.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `49535343-fe7d-4ae5-8fa9-9fafd205e455` | Astral Service | ISSC transparent UART |
| `49535343-1e4d-4bd9-ba61-23c647249616` | TX | Phone → device (write) |
| `49535343-8841-43f4-a8d4-ecbe34729bb3` | RX | Device → phone (notify) |

Transparent UART: plain ASCII bytes both ways, no framing. The app never negotiates an MTU —
split long writes into 16-byte GATT writes with ~10 ms spacing.

### Commands

App → device commands are `#`-prefixed ASCII strings. The most useful:

| Command | Description |
|---------|-------------|
| `#GM` | Query current mode (replies `&M…`) |
| `#GV` | Query firmware version |
| `#GS`/`#GT`/`#GD`/`#GA`/`#GO`/`#GE`/`#GL`/`#GN` | Settings query chain: sleep seconds, POV stabilization, LED count, battery type, prop type, LED type, battery level, product ID |
| `#SM2=<mode>;1=<item>;` | Set display mode and menu item |
| `#SM3=<speed>;4=<hue>;` | Set custom speed and hue |
| `#SO<i>` / `#SE<i>` / `#SA<i>` | Set prop type / LED type / battery type index |
| `#SD<hi><lo>` | Set LED count (2 raw big-endian bytes on fw ≥ 5.2; 1 byte older) |
| `#SS<n>` | Set auto-sleep seconds (0 = off) |
| `#ST0` / `#ST1` | POV stabilization off / on |
| `#V` + byte(46+slot) | Preview stored pattern slot |
| `#D` | Begin pattern image upload (expect `OK`) |
| `#WIPE` / `#FORMAT` | Clear customizations / reformat pattern storage |
| `#B` + `MCURESET` | Enter firmware-update bootloader (expect `BL`) |

Device → phone messages on RX are `&`-prefixed status records (`&M` mode, `&L` battery 0-7,
`&S` sleep, `&B` brightness, `&T` POV stabilization, `&D` LED count, `&A`/`&O`/`&E` type
indices, `&N` product ID, `&V` version), pushed spontaneously on state change and in reply to
the `#G*` queries, plus simple ACKs: `OK`, `BL`, and single-byte `0x06` ACK / `0x18` CAN on
the XMODEM path.

### Pattern upload

Custom POV patterns persist on the prop in numbered slots:

1. Send `#D`, wait for `OK`.
2. Send a 10-byte header: `[width, height, 3, 0,0,0,0,0,0,0]` (3 = RGB888).
3. Send gamma-corrected RGB888 pixel data in **20-byte chunks**, waiting for `OK` after each.
4. Send one final byte = the pattern slot to save into, expecting `OK`.

`#FORMAT` erases pattern storage; the factory art is then restored by re-uploading images the
same way. Free pattern packs are hosted at
[extras.astralhoops.com/patterns/](https://extras.astralhoops.com/patterns/).

### Firmware OTA

The vendor publishes firmware openly: [a5.ver](https://astralhoops.com/images/a5.ver) (plain
text version) and [af5.bin](https://astralhoops.com/images/af5.bin) (raw flash image for
offset `0x2000`; beta: `a5beta.ver` / `af5beta.bin`). Updating means entering the custom
SAM D21 bootloader (`#B`, `MCURESET` → `BL`), verifying the chip ID, erasing the app region,
writing the image word-by-word staged through RAM, and resetting. The exact command sequence
is documented in the device spec's `firmware_update` feature. **This path can brick the prop
if interrupted** — it is documented for owners reflashing their own hardware, and has not yet
been replayed against a live unit by this project.

## Open Questions

- Exact `#GV`/`&V` reply layout (string vs `0x05`-led binary triplet) — needs a live capture.
- `&M` payload semantics and the mode/item index tables (they live in app UI resources).
- Whether the XMODEM block path in the bootloader is still used, or legacy.
- Exact gamma-correction table used for pattern upload (a standard LED gamma ramp is a close
  approximation; capture for bit-exact colors).

## Tools Used

- [x] APK static analysis (jadx)
- [x] Live fetch of the public firmware/version endpoints
- [ ] HCI snoop of connect + settings chain + pattern upload (pending)

## References

- [Astral Hoops](https://astralhoops.com/)
- [AF-series instructions](https://shop.astralhoops.com/pages/instructions-af)
- [Firmware version (release)](https://astralhoops.com/images/a5.ver) /
  [firmware image](https://astralhoops.com/images/af5.bin)
- [Pattern gallery](https://extras.astralhoops.com/patterns/)
- [Astral app on Google Play](https://play.google.com/store/apps/details?id=com.astral.astral)

## Contributors

- Liberated Bread research team — initial app analysis and protocol mapping
