# wl.smartled Pixel Strips (duoCo StripX / Lotus Lantern / Magic Lantern)

> **Status**: Complete (static analysis; live capture pending)
> **Protocol**: BLE
> **Manufacturer**: Unbranded / various OEMs (shared "fstart"/easylink platform)
> **Manufacturer Status**: Unsupported

## Overview

Cheap addressable-pixel ("dream colour" / "symphony") LED strip controllers sold under
dozens of listings, all driven by one of three vendor apps — **duoCo StripX**
(`wl.smartled.duoco.rgb`), **Lotus Lantern** (`wl.smartled`) or **Magic Lantern**
(`wl.smartled.rgb`). The three apps are channel skins of a single shared codebase and
speak **one protocol**: fixed 9-byte frames to a single BLE characteristic, no
pairing, no account, no cloud. Local-only replacement control is fully viable.

These are **pixel** strips — 241 built-in chase/flow effects, configurable pixel
count, music-reactive modes. If your controller notifies state on a second
characteristic (`0xFFF4`) and treats byte 1 of the frame as a sequence number, you
have the sibling **PWM** (single-color) protocol instead — see the ELK-BLEDOM family;
the two share the `0xFFF3` characteristic but are not the same protocol.

| App | Package | Advertised-name filter |
|-----|---------|------------------------|
| duoCo StripX | `wl.smartled.duoco.rgb` | `MELK-` (with model-variant gating) |
| Lotus Lantern | `wl.smartled` | `ELK-`, `ELK~`, `XSL-`, `LED LIGHT STRIP` |
| Magic Lantern | `wl.smartled.rgb` | `MELK-` |

## Hardware

| Property | Value |
|----------|-------|
| Controller | Unbranded BLE pixel-strip controller (SoC likely Bluetrum/Beken-class — inference, not confirmed) |
| Radio | BLE (GATT); `ELK_*` mesh variants also controllable via BLE advertising relay |
| Advertised names | `MELK-*`, `ELK-*`, `ELK~*`, `XSL-*`, `LED LIGHT STRIP` |
| Output | Addressable RGB pixel strip (pixel count configurable, 16-bit) |
| Extras | External mic on most models; CCT and RGBW variants; timers/alarms on-device |

## Initial Setup

No setup in the usual sense — this is a `ble_direct` device.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Advertised name | `MELK-…` / `ELK-…` / `ELK~…` / `XSL-…` / `LED LIGHT STRIP` |
| Passphrase protection | not_applicable |
| Confidence | high (from app analysis; not yet replayed on hardware) |

Power the strip, scan for service `0xFFF0`, connect. No pairing, no PIN, no account.
The vendor app's only post-connect ritual is one read of `0xFFF3` (a connection
probe) followed by a clock-sync frame so the on-device timers work — a replacement
client should do the same.

**Factory reset**: there is nothing to reset — the device holds no credentials and is
bound to no network or account. Power-cycle it; that also frees the single BLE link
if another phone is holding it. Timers and the clock persist until overwritten.

**Rebinding to a new controller**: just connect from the new phone. If the old phone
keeps grabbing the link, remove the device from its OS Bluetooth list so it stops
auto-reconnecting.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | Pixel Strip Service | Only service |
| `0000fff3-0000-1000-8000-00805f9b34fb` | Command / Readback | Write (all commands) **and read** (probe + timer readback). **No notify.** |

### Command framing

Every command is a fixed **9-byte** frame; no checksum, no encryption:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `0x7E` header |
| 1 | 1 | Per-command constant `0x04`–`0x08` (copy verbatim, do not compute) |
| 2 | 1 | Opcode |
| 3–6 | 4 | Payload (`0xFF` = unused) |
| 7 | 1 | Flag/routing byte (`0x10` static color, `0x20` music color, `0x08` CCT/palette, `0x01` scene, `0x00` most others) |
| 8 | 1 | `0xEF` trailer |

### Commands

| Command | Frame | Notes |
|---------|-------|-------|
| Power on | `7E 04 04 01 00 01 FF 00 EF` | Payload bytes become `FF` on "INTRO" models |
| Power off | `7E 04 04 00 00 00 FF 00 EF` | |
| Brightness | `7E 04 01 bri mode FF FF 00 EF` | bri 0–100; mode 0=all/1=RGB/2=W/3=CCT |
| Effect speed | `7E 04 02 spd FF FF FF 00 EF` | 0–100 |
| Effect mode | `7E 05 03 mode 06 FF FF 00 EF` | 241-entry table; 0 = Auto Play |
| Scene | `7E 05 31 scene 07 FF FF 01 EF` | 1–28; 156 = "Big Bang" (DYDS models) |
| Static RGB | `7E 07 05 03 R G B 10 EF` | |
| Music color | `7E 07 05 03 R G B 20 EF` | Amplitude pre-multiplied; sent at audio rate |
| Palette color | `7E 05 05 01 idx FF FF 08 EF` | Device palette index |
| Color temperature | `7E 06 05 02 warm cold FF 08 EF` | CT models only |
| Mic sensitivity | `7E 04 06 sens FF FF FF 00 EF` | 0–100 |
| Mic on/off | `7E 04 07 on FF FF FF 00 EF` | |
| Mic EQ mode | `7E 07 03 (eq+80) 04 FF FF 00 EF` | eq 0–7 |
| RGB pin order | `7E 06 81 c1 c2 c3 FF 00 EF` | Permutation of `01 02 03`; fixes swapped colors |
| Pixel count | `7E 07 21 lo hi 00 FF 00 EF` | uint16 little-endian |
| Set clock | `7E 07 83 H M S days FF EF` | Push after every connect |
| Set timer | `7E 08 82 H M S mode days EF` | mode 0=on-alarm/1=off-alarm; days bit7=enable |
| Query timer | `7E 08 82 FF FF FF mode FF EF` then **read** `0xFFF3` | Reply `7E 08 82 H M S mode days EF` |

The 241-effect mode table (groups: Basic / Curtain / Trans / Water / Flow / Tail /
Run / RunBack, plus 28 scenes) is transcribed in full in
`device-specs/devices/wl-smartled-pixel-strips.yaml`.

### Model-variant gating (from the advertised name)

- `MELK-OC` / `MELK-OT` → scene tab available
- name matching `^MELK-.+CT` → color-temperature model; `^MELK-.+W` → white channel
- `MELK-OE` / `MELK-OB` / `MELK-TX` → no external mic (`TX` is a remote/transmitter)
- `MELK-DYDS` → extra "Big Bang" scene (code 156)
- name containing `INTRO` → power-on payload byte is `0xFF` instead of `0x01`

### Other transports on the same family

- **Broadcast relay** (`ELK_*` mesh devices): the phone itself advertises
  manufacturer-data frames (company id `0xBEE8`) carrying the same 9-byte command,
  obfuscated with a counter-derived single-byte XOR. Connectionless — no GATT needed.
- **Encrypted variant** (names containing `ELK-*`): the 9-byte frame is wrapped in a
  21-byte `AA…55` obfuscation layer (per-frame random keystream + a key hardcoded in
  the app, recoverable from the APK). Obfuscation grade, not real security.

## Open Questions

- Which advertised suffixes real hardware uses, and whether the name-gating table
  matches actual firmware capabilities (needs a live scan).
- The Lotus Lantern build sends effect modes as `(mode+0x80)` with a different
  byte-4 constant than duoCo StripX — which form a given hardware revision accepts
  is unverified.
- Whether `ELK-*` encrypted devices also wrap their *responses*.
- Firmware-side clamps for brightness/speed/CCT and the pixel-count range.

## Tools Used

- [x] APK static analysis (jadx) — all three vendor apps
- [ ] HCI snoop of a live session (pending)
- [ ] nRF Connect scan of real hardware name variants (pending)

## References

- [duoCo StripX on Google Play](https://play.google.com/store/apps/details?id=wl.smartled.duoco.rgb)
- [Lotus Lantern on Google Play](https://play.google.com/store/apps/details?id=wl.smartled)
- [Magic Lantern on Google Play](https://play.google.com/store/apps/details?id=wl.smartled.rgb)
- ELK-BLEDOM PWM LED strip spec (`device-specs/devices/elk-bledom-led-strip.yaml`) — sibling single-color protocol on the same `0xFFF3` characteristic
- [dave-code-ruiz/elkbledom (HACS)](https://github.com/dave-code-ruiz/elkbledom) — ELK-family PWM sibling, family context
- [FergusInLondon/ELK-BLEDOM](https://github.com/FergusInLondon/ELK-BLEDOM) — clean-room RE of the ELK-BLEDOM app

## Contributors

- Liberated Bread research — static analysis of all three vendor apps
