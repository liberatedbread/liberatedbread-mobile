# LEDs2RAVE4 / Lunchbox Dream LED

> **Status**: Complete
> **Protocol**: BLE
> **Manufacturer**: SPLED (SP107E/SP110E) / Host No.4 Technology (SPOTLED) / Shenzhen I-ledshow (iLEDColor)
> **Manufacturer Status**: Unsupported

## Overview

The LED skins and panels sold by [Lunchbox Packs](https://www.lunchboxpacks.com/) — built in
collaboration with [LEDs 2 RAVE 4](https://leds2rave4.com/) — are not one device. Across three
product generations the pack has shipped with three different controller boards, and **each
generation is designed with a different phone app**. If you are looking for "the app that does
the designs on the LED panel on the Lunchbox backpack", the answer depends on which Dream Skin
you have.

| Generation | Product | Design app | Android package | Controller / protocol |
|------------|---------|-----------|-----------------|-----------------------|
| v1 | Dream LED Skin | **LED CHORD** | `com.spled.pzse` | SP107E SPI pixel controller (`0xFFE0`) |
| v2 | Dream LED Skin 2.0 | **SPOTLED** | `com.led.spotled` | Matrix panel, SPOTLED framed protocol (`0xFF20`) |
| v3 (early batches) | Dream Skin 3.0 / DreamPanel | **SPOTLED** | `com.led.spotled` | Matrix panel, SPOTLED framed protocol (`0xFF20`) |
| v3 (recent + future batches) | Dream Skin 3.0 / DreamPanel | **iLEDColor** | `com.led.iledcolor` | New board revision — protocol **not yet captured** |

!!! note "Which app do I need for a DreamPanel v3?"
    LEDs 2 RAVE 4 changed the controller board partway through the v3 run. Their guidance is to
    power the panel on and look at the serial number: if the serial number renders **horizontally**,
    the unit is a new-board revision and uses **iLEDColor**; older units stay on **SPOTLED**.
    The two apps are not interchangeable.

The v1 skin is a strip/pixel product — LED CHORD sets colors, effects and speed on an SPI
controller. From v2 onward the product is a genuine addressable **matrix panel** where the app
is a bitmap/GIF design tool: you draw, import an image or GIF from your camera roll, or pull from
the app's content library, and the app renders it to the panel's pixel geometry and uploads frames
over BLE. Dream Skin 3.0 is advertised at 2048 LEDs (double the 2.0 panel).

!!! warning "Unverified: panel geometry"
    The 2048-LED figure is a vendor claim. The pixel arrangement (64×32 is the obvious candidate)
    has **not** been confirmed here. Do not hardcode it — the SPOTLED protocol has a
    `GetDisplayInfoCommand` that returns the panel's real width/height/color depth; query it.

## Hardware

| Property | Value |
|----------|-------|
| v1 controller | SP107E ("LED Chord"), SP110E ("LED Hue") SPI pixel controllers |
| v2/v3 hardware | Addressable RGB matrix panel, geometry reported by the device |
| Chipset | Unknown |
| Radio | BLE |
| Supported LED ICs (v1) | WS2811, SK6812, APA102, and 23 more |
| Power | External USB power bank (Lunchbox "Powerbox" or any 10,000 mAh+ bank) |

## Design Apps

### LED CHORD (`com.spled.pzse`) — v1

Generic SP107E/SP110E controller app. Not a design tool: it picks from a fixed catalog of
built-in effects and sets color, brightness and speed. Rated ~3.3 on Play.

### SPOTLED (`com.led.spotled`) — v2 and early v3

The actual design app for the matrix panels. Publisher: Wen Lv (Android) / Host No.4 Technology
(Chengdu) Co., Ltd. (iOS). Supports full-color text with fonts and scroll effects, freehand
"graffiti" drawing, still image upload, GIF animation upload and music-rhythm display. This is
the app the Lunchbox Dream LED Skin 2.0 setup guide tells you to install, and it is what most
Lunchbox owners in the field are using.

Devices are connected from inside the app ("Click to connect device") rather than through system
Bluetooth pairing.

**The SPOTLED BLE protocol is fully reverse engineered** — see below.

### iLEDColor (`com.led.iledcolor`) — recent and future v3 batches

Publisher: Shenzhen I-ledshow Technology Co., Ltd. Same feature space as SPOTLED — patterns, text,
graffiti, GIF import, music/microphone rhythm — plus a searchable online material library. Rated
~2.2 on the App Store with recurring complaints about forced account registration, crashes after
updates and lost saved programs, which is exactly the failure profile this project exists to fix.

A prior static pass over this APK (recorded in the device spec) found **no BLE UUIDs in the
decompiled output**, suggesting the transport is set up dynamically or the app is cloud-mediated.
This is the highest-value open item on this target: iLEDColor is the app shipping on new hardware
today and its protocol is undocumented. Live HCI capture is required.

## Protocol Summary

### v2/v3 — SPOTLED framed protocol

These panels are members of the wider SPOTLED family, which spans many unrelated resellers.
**The full protocol is documented in [SPOTLED LED Panels](spotled-led-panel.md)** — that page is
canonical; this section is a summary of what applies to a Lunchbox panel.

| UUID | Name | Description |
|------|------|-------------|
| `0000ff20-0000-1000-8000-00805f9b34fb` | SPOTLED Service | Primary service |
| `0000ff21-0000-1000-8000-00805f9b34fb` | Command | Control commands, notifications |
| `0000ff22-0000-1000-8000-00805f9b34fb` | Data | Bulk payload channel |

The essentials for a Lunchbox panel:

- Bootstrap by enabling notifications, then `GetBufferSize` (`04 14 00 00`) and `GetDisplayInfo`
  (`04 12 00 00`). Both are required — chunk pacing and rendering depend on them.
- **Query geometry, never assume it.** `GetDisplayInfo` returns real width, height, color depth
  (16 mono / 255 RGB), frame limit and brightness. The 2048-LED figure on the v3 box is marketing.
- Content is uploaded to `0xFF22` as bitmap frames wrapped in a 15-byte header plus typed records
  (brightness is record type 14, screen mode 15, animation frames 96).
- Uploads are gated by the device: write `MTU − 3` byte chunks and resume from the offset carried
  by each `ContinueSending` notification. A `PauseSending` response means a bad MTU — chunks too
  large *or* too small.

### v1 — SP107E / SP110E SPI controllers

All commands are 4 bytes: `[data1] [data2] [data3] [cmd_byte]`, written to `0xFFE1`.

#### SP107E Commands

| Command | Bytes | Description |
|---------|-------|-------------|
| Power On | `00 00 00 AA` | Turn on |
| Power Off | `00 00 00 BB` | Turn off (note: `0xBB`, not `0xAB`) |
| Set Color | `RR GG BB 0C` | Set static RGB color |
| Set Brightness | `VV 00 00 0A` | Brightness 0x00-0xFF |
| Set Effect | `VV 00 00 08` | 0x01-0xB4=dynamic, 0xB5=static |
| Set Speed | `VV 00 00 09` | Speed 0x01-0xBA |
| Set Sensitivity | `VV 00 00 13` | Audio input gain 1-165 |
| Query Status | `00 00 00 02` | Returns 26 bytes (2 packets) |

#### SP110E Commands

| Command | Bytes | Description |
|---------|-------|-------------|
| Power On | `00 00 00 AA` | Turn on |
| Power Off | `00 00 00 AB` | Turn off |
| Set Color | `RR GG BB 1E` | Set static RGB color |
| Set Brightness | `VV 00 00 2A` | Brightness 0x00-0xFF |
| Set Effect | `VV 00 00 2C` | 0x01-0x78=dynamic, 0x79=static |
| Set Speed | `VV 00 00 03` | Speed 0x01-0xBA |
| Set Chip Type | `VV 00 00 1C` | IC model index |
| Set Chip Order | `VV 00 00 3C` | RGB sequence 0x00-0x05 |
| Set Pixel Count | `HI LO 00 2D` | Big-endian, 1-1024 |
| Query Status | `00 00 00 10` | Returns 12 bytes |

### Discovery

| Signal | Meaning |
|--------|---------|
| Local name `SP107E` | v1 SP107E controller — use the SP107E command set |
| Local name `SP110E` | v1 SP110E controller — use the SP110E command set |
| Local name prefix `LBXDRMSKIN_LED_` | Lunchbox Dream Skin matrix panel — SPOTLED protocol on `0xFF20` |
| Service `0000ff20-…` present | SPOTLED framed protocol |
| Service `0000ffe0-…` present | SP107E 4-byte command protocol |

For an unknown Lunchbox panel, probe for the `0xFF20` service first; if it is present, issue
`GetDisplayInfo` and let the device tell you its geometry rather than guessing from the
advertised name.

## Open Questions

- **iLEDColor protocol is unmapped.** New DreamPanel v3 boards ship with it and the static pass
  produced no UUIDs. Needs an HCI snoop of connect + upload one small GIF.
- **DreamPanel v3 pixel geometry** unconfirmed (2048 LEDs claimed; arrangement unknown).
- Whether the `0xFF20` SPOTLED panel firmware is genuinely an "SP110E" board or an unrelated
  matrix controller that the SP110E label was mistakenly attached to. The SPOTLED framed
  transport does not resemble the SP110E 4-byte command set.

## Tools Used

- [x] Community open-source implementations (`python-spotled`, UniLED, SP110E-HASS)
- [x] APK static analysis (jadx)
- [ ] HCI snoop of iLEDColor (pending — highest priority)

## References

- [Lunchbox Packs — Dream LED Skin tutorial (LED CHORD, SP107e)](https://www.lunchboxpacks.com/pages/dream-led-tutorial)
- [Lunchbox Packs — How to set up your Dream LED Skin 2.0 (SPOTLED)](https://www.lunchboxpacks.com/blogs/resources/how-to-set-up-your-dream-led-skin-2-0)
- [LEDs 2 RAVE 4 — DreamSkin v3: The DreamPanel](https://leds2rave4.com/products/dreamskin-v3-the-dreampanel)
- [LEDs 2 RAVE 4 — New batch of V3's now use iLEDColor app](https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app)
- [SPOTLED LED Panels](spotled-led-panel.md) — canonical SPOTLED protocol reference
- [`python-spotled` — reverse-engineered SPOTLED BLE library](https://github.com/iwalton3/python-spotled)
- [Google Play — SPOTLED](https://play.google.com/store/apps/details?id=com.led.spotled)
- [App Store — iLEDColor](https://apps.apple.com/us/app/iledcolor/id6737223690)
- [SP110E Protocol Gist](https://gist.github.com/mbullington/37957501a07ad065b67d4e8d39bfe012)
- [UniLED HA Integration](https://github.com/monty68/uniled)
- [SP110E-HASS](https://github.com/roslovets/SP110E-HASS)

## Contributors

- @iwalton3 -- `python-spotled`, SPOTLED BLE protocol reverse engineering
- @mbullington -- SP110E protocol documentation
- @monty68 -- UniLED Home Assistant integration
