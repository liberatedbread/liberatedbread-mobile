# Yummly Smart Thermometer

> **Status**: Spec Available (unverified; XW3 generation protocol-mapped only)
> **Protocol**: BLE
> **Manufacturer**: Yummly (Whirlpool Corporation brand); hardware reported as a Mastrad Meat°it white-label
> **Manufacturer Status**: Shutdown — thermometer app stopped 18 December 2024, Yummly website and apps closed 20 December 2024

## Overview

A wireless meat thermometer: a stainless probe (P1 or P3) with a core sensor
in the tip and a second sensor in the body, charged in and relayed by a
battery-powered dock (T1 or T3). The phone talks to the **dock** over BLE GATT;
the dock wraps the probe's frames in the probe's address and forwards them.

Whirlpool laid off the Yummly team in April 2024 and shut the service down in
December 2024, and the app stopped reading the probe. The hardware did not
change: after a one-byte challenge reply any BLE client receives the
temperature stream. The protocol was recovered from the vendor Android app
and run against one T1 + P1 by
[DavisGoglin/yummly-thermometer](https://github.com/DavisGoglin/yummly-thermometer)
(MIT), which is the source of every byte in this spec.

Two generations differ in almost everything on the wire:

| Generation | Dock | Probe | Wire | Status |
|------------|------|-------|------|--------|
| XW2 | Yummly T1 (legacy "Meat D2") | Yummly P1 ("Meat X1") | TLV frames on one UART-style service, challenge reply, bit-rotation packing, **Fahrenheit** | Run against hardware by the source project |
| XW3 | Yummly T3 | Yummly P3 ("Meatit X3") | One characteristic per reading, no challenge, int16 **Celsius** | From the app only; untested by anyone |

**Food safety.** The core reading leaves the probe obfuscated; decode it
exactly as the spec says, and confirm doneness with an instant-read
thermometer against published safe minimum internal temperatures. The second
channel is the probe *body*, not the oven air. The spec carries a
`safety_advisory` saying so.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (the vendor's web activation is gone and was never needed by the hardware) |
| Method | `ble_direct`, one route per generation — XW2: connect to the dock, answer the challenge, listen; XW3: subscribe to the six telemetry characteristics and query the dock (untested) |
| Advertised | Exact names `Yummly T1`, `Yummly T3`, `Meat D2`; manufacturer data company id 711 (`0x02c7`, read as `0xc702` by the vendor app) |
| Passphrase protection | not_applicable |
| Confidence | medium (one open-source client, one unit) |

Fit two AAA cells in the dock and charge the probe in it for at least 30
minutes (manual). The dock only advertises while awake: lift the probe out, or
wait for the blue LED to blink.

**Factory reset**: unknown. The manual's parts list names a pairing button on
the dock and never says what it does; nothing in the protocol needs a reset.
Removing the AAA cells is the only established way to restart the dock.

**Rebinding**: BLE only, no account binding on the device. Any central that
answers the challenge reads the probe.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `app_layer` (one-byte challenge reply on XW2; none reported on XW3) |
| Bonding | `none` — the vendor app never bonded |
| One central at a time | Assumed yes (untested) |
| Confidence | medium |

**Recovery**: disconnect any other client, wake the dock by lifting the probe
out, or remove and refit the AAA cells.

## Protocol Summary

### XW2 (T1 + P1)

| UUID | Name | Description |
|------|------|-------------|
| `6e40abcd-b5a3-f393-e0a9-e50e4159414d` | Service | Nordic-UART pattern with changed short parts |
| `6e40aa02-b5a3-f393-e0a9-e50e4159414d` | Request | Write with response |
| `6e40aa03-b5a3-f393-e0a9-e50e4159414d` | Replies / telemetry | Notify: challenge ping, replies, probe stream |
| `0000fe59-0000-1000-8000-00805f9b34fb` | Nordic Secure DFU | Present, unused by the app; firmware path only |

**Frame**: `size | type | value`, where **size is the index of the last value
byte** (value length + 1); a request with no value is `01 <type>`. Probe frames
are wrapped: `07 07 <probe address, 6 bytes reversed> | inner size | inner type
| inner value`.

**Challenge**: after notifications are enabled the dock sends `01 ab` every
~2 s. Reply `02 aa <code>` on the request characteristic, `<code>` one of
`02`, `11`, `28` (brand id 2 rotated right by 0, 1 or 2 bits in a 4-bit field,
with the rotation count in the top nibble). The dock accepts any of the three.

**Request byte ≠ reply type** — a request written with the reply's byte is
ignored:

| Reading | Request | Reply type | Payload |
|---------|---------|------------|---------|
| Dock firmware | `01 09` | `04` | ASCII (`05 04 '1.53'`) |
| Dock battery | `01 16` | `15` | one packed byte (`02 15 2d` = 3 bars) |
| Probe address | `01 21` | `20` | 6 bytes reversed |
| Probe status | `01 32` | wrapped `1e` | `04` = connected |
| Probe firmware / name / battery | `07 07 <addr> 01 11` / `23` / `0c` | wrapped `12` / `22` / `03` | ASCII / ASCII / packed byte |
| Core temperature | — (streamed ~2 s) | wrapped `01` | 3 bytes packed, tenths of °F |
| Body temperature | — (streamed ~2 s) | wrapped `02` | 2 bytes packed, whole °F |

**Rotation packing**: a packed value is a 4-bit selector `s` over a `W`-bit
field (`W` = 20 core, 12 body, 4 battery) holding the reading rotated right by
`s`. Decode by rotating the field left by `s` within `W` bits:
`((field << s) | (field >> (W - s))) & ((1 << W) - 1)`. Then clamp the core
value to 320–2120 and divide by 10 (°F); clamp the body value to 32–572 (whole
°F); map battery 0–9 to bars (1–3 → 1, 4–5 → 2, 6–8 → 3, 9 → 4).

Worked: `4b 01 20` → `0x20014b` → s = 2, field `0x0014b` → 1324 → 132.4 °F.
`2d` → s = 2, nibble `1101` → `0111` = 7 → 3 bars. `33` → 9 → 4 bars.

The XW2 dock battery, probe battery and body temperature have no entity in the
spec: the schema binds one layout per characteristic and the core frame takes
it; they are laid out in `payload_formats`.

### XW3 (T3 + P3) — from the app, untested

| UUID | Name | Description |
|------|------|-------------|
| `6f2faaaa-a6b6-4571-8bfd-5fe8a70600f0` / `6f2f0100-…` | Command | One byte for the dock (`14` firmware, `11` model, `13` date, `50` probes, `01` DFU); `a0 <addr reversed> <cmd>` for the probe |
| `f84cbbbb-b8bb-494e-86c5-01fd7341f217` / `f84c1001-…` | Replies | Byte 0 echoes the command, or `30` status, `31` RSSI, `a0` probe sub-reply |
| `f84c1002-…` | Dock battery | uint8 % at offset 0 |
| `f84c2000-…` | Probe battery | uint8 % at offset 6 |
| `f84c3001-…` / `3002` / `3003` | Core / body / tip temperature | int16 LE at offset 6, ×0.1 °C |

### Firmware update

Both generations run Nordic Secure DFU on nRF52832. The XW3 commands that
enter the bootloader (`01` for the dock, `a0 <addr> 01` for the probe) and the
XW2 `01 ac` probe request are declared `advanced`; update mode advertises as
`DFU T3` / `DFU P3` on XW3 and is unobserved on XW2. No vendor image is
obtainable any more.

`scripts/test_yummly_smart_thermometer_spec.py` re-implements the rotation
decode and the challenge code with the standard library and holds the spec's
vectors and published frames to them.

See `device-specs/devices/yummly-smart-thermometer.yaml` for the full
machine-readable spec.

## References

- [DavisGoglin/yummly-thermometer](https://github.com/DavisGoglin/yummly-thermometer) — client, protocol write-up and notes (MIT)
- [Yummly YTE000W5K user manual (ManualsLib)](https://www.manualslib.com/guide/3024165/yummly-yte000w5k-smart-thermometer-manual.html)
- [Yummly Help Center, Smart Thermometer (Wayback, 21 Dec 2024)](https://web.archive.org/web/20241221010004/https://help.yummly.com/hc/en-us/categories/360002376231-Smart-Thermometer)
- [Amana Product Help: starting the thermometer (Wayback, May 2024)](https://web.archive.org/web/20240521221620/https://producthelp.amana.com/Cooking/Yummly/Yummly_Support/Starting_your_Yummly_Smart_Thermometer)
- [Plan to Eat: Yummly is closing (Dec 2024)](https://www.plantoeat.com/blog/2024/12/yummly-is-closing-discover-the-best-meal-planning-alternative/)
- [The Spoon: Whirlpool lays off the Yummly team (Apr 2024)](https://thespoon.tech/whirlpool-lays-off-entire-team-for-cooking-and-recipe-app-yummly/)
