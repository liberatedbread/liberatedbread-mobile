# Pix Backpack / Pix Mini

> **Status**: Spec Available (untested)
> **Protocol**: BLE
> **Manufacturer**: Pix Inc.
> **Manufacturer Status**: Shutdown (vendor defunct, app delisted from Google Play)

## Overview

The **Pix Backpack** (Kickstarter 2018) is a backpack with a 16×20 RGB LED matrix
sewn into the back panel; the **Pix Mini** (2019) is a smaller kids' variant. Both
were driven by the vendor's **Pix** app (`style.pix.app`), a React Native app that
has since vanished from the Play Store along with the vendor. The good news: the
hardware never needed the cloud. Every control function — image and animation
upload, brightness, scrolling text, widgets, games — is plain local BLE with no
pairing, no account and no encryption. The full machine-readable protocol is in
[`device-specs/devices/pix-backpack.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/pix-backpack.yaml).

The vendor cloud only ever hosted the content marketplace, a news feed, and
firmware files — all replaceable or unnecessary.

Everything here comes from static analysis of the vendor app. No hardware has
been driven from this document yet, so byte layouts are `reported`, not
`confirmed`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Pix Backpack (16×20 matrix), Pix Mini (geometry unconfirmed) |
| Chipset | Unknown — ESP32-class suspected (BLE + Wi-Fi combo, Wi-Fi OTA); unconfirmed |
| Radio | BLE (control); Wi-Fi used only by the device itself during firmware OTA |
| Power | External USB power bank (no internal battery) |
| FCC ID | Unknown (no grant found under Pix Inc.) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Setup AP / advertised name | `pix <12-hex-MAC>` (e.g. `pix aabbccddeeff`) |
| Passphrase protection | plaintext (only during OTA — see below) |
| Confidence | medium (from app analysis; not yet exercised against hardware here) |

Plug the backpack's internal USB cable into a power bank — the display powers on
and advertises immediately. Scan for the `pix …` name (or the `0100` service
UUID), connect from inside your app, and read the matrix width, height and max
frame count from the device. There is no pairing, PIN, or account.

**Factory reset**: none exists — and there is little to reset, since the device
holds no accounts or keys. The only persistent state is the saved animation,
which you can erase over BLE (frame count 0, then save-to-flash). A hardware
reset procedure is unknown.

**Rebinding to a new controller**: just connect from the new phone — nothing binds
the backpack to a controller, and there is no network to rejoin (Wi-Fi is used
only during a firmware update).

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | — (no PIN) |
| One central at a time | Unknown |
| One bond at a time | No (nothing bonds) |
| Confidence | medium (app analysis; unreplayed) |

**Entering pairing mode**: not needed — the backpack accepts a connection
whenever it is powered.

**Unpairing**: nothing is stored on either side, so there is nothing to unpair,
and a second-hand unit can be adopted without a reset.

**Recovery**: if a connect times out, close the vendor app (or whatever other
phone last drove the backpack) and retry; unplugging the power bank for a few
seconds drops any stale link.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00000100-e984-11e7-b78e-ffd6fcc3450f` | Pix RPC (legacy base) | Main service, legacy firmware |
| `00000100-e984-11e7-b78e-ffd6fcc34510` | Pix RPC (V1 base) | Main service, current firmware |
| `00000100-9552-4325-8021-a85f8136a5c4` | Pix RPC (Mini) | Mini variant — unconfirmed |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Firmware revision `00002a26-…`, hardware revision `00002a27-…` |

Both original bases expose the same characteristics; pick the legacy base only if
the device actually advertises it, otherwise V1. Characteristics (the `xxxx` part
of `0000xxxx-e984-11e7-b78e-ffd6fcc3450f` / `…34510`, same under each base):
`0101` RPC write, `0103`/`0104`/`0105` width/height/max frames (read), `0106`
brightness (write, one byte 0–255), `0107`/`0108`/`0109` OTA, `0110` demo.

### Commands

Every command is a write to `0101`: `[callId, opcode, payload…]` — `callId` is a
rolling counter, and there is **no checksum, no encryption and no ACK**.

| Opcode | Name | Payload |
|--------|------|---------|
| 0 | SET_FRAME | frame index (u16LE), offset (u16LE, =0), frame bytes |
| 1 | SET_PALETTE | start color index, RGB888 bytes (≤160 colors per call) |
| 2 | SET_FRAME_COUNT | count (0 = erase) |
| 3 | SET_FRAMES_DURATIONS | offset (u16LE), per-frame milliseconds (u16LE each; default 80) |
| 4 | SET_ANIMATION_DIRECTION | 0 normal / 1 alternate / 2 normal-stop / 3 alternate-stop |
| 5 | SAVE_TO_PERSISTENT_MEMORY | — (saved content autostarts on boot) |
| 6 | PRINT_MEMORY | — (debug; never sent by the app's normal flows) |
| 7 | SET_CONFIG | offset (u16LE), config bytes (≤512 per call); first byte = render mode |
| 8 | SET_INPUT | input id (rolling), command (widget/game input) |
| 9 | RESTART | — |

Render modes (first SET_CONFIG byte): 0 blank, 1 animation, 2 scrolling text,
3 OTA progress, 6 clock, 7 bike, 8 countdown, 9 stopwatch, 16–18 games. Since
each game and widget is a device render mode that takes input through
SET_INPUT, they appear to run on the device rather than being streamed frame by
frame from the phone (unconfirmed on hardware).

### Image / animation upload

Frames are **one byte per pixel — an index into an RGB888 palette** — row-major,
320 bytes per frame at 16×20. Upload sequence (all fire-and-forget writes):

1. Blank the screen (SET_CONFIG mode 0) and erase (SET_FRAME_COUNT 0).
2. Upload the palette (SET_PALETTE; a second call at index 160 if >160 colors).
3. Upload each frame (SET_FRAME).
4. Set durations, direction, then the real frame count.
5. Optionally SAVE_TO_PERSISTENT_MEMORY so it plays on boot.

Scrolling text works by uploading 8×20 font sprites as ordinary frames and then a
text config naming the sprite sequence.

### Firmware OTA (rescue notes)

Unusually, the **device** downloads its own firmware over Wi-Fi: the phone writes
a config blob (Wi-Fi SSID/password, host, **port 80**, path, image size, MD5) to
`0108`, arms `0107`, and the backpack joins that network and plain-HTTP GETs the
image while still running its normal firmware — there is no bootloader to reboot
into first. The vendor app only offers this on hardware revision 3.1 or later,
and only on a 2.4 GHz network.

That makes OTA rescuable — any HTTP server on port 80 serving an image with the
matching size/MD5 will do — but no firmware image is publicly archived, the
image format is unknown, whether the device checks a vendor signature is
unknown, and a bad flash can brick the backpack. The spec marks every OTA
command `advanced`. Note the passphrase crosses the BLE link in cleartext; use
a throwaway hotspot.

## Open Questions

- Does the RPC characteristic stream responses if you subscribe to notifications?
  (The vendor app never does.)
- Real max-frame count and palette cap; partial-frame writes via SET_FRAME offset.
- Config layouts for the clock/bike/timer widgets and the three games.
- Pix Mini matrix geometry and whether its characteristic layout matches.
- Chip family and firmware image format (needs an FCC ID or an archived image).
- What the backpack advertises, if anything, while it downloads and flashes an
  update, and what an interrupted flash leaves behind.

## Tools Used

- [x] APK static analysis (React Native bundle)
- [ ] HCI snoop of connect + upload (pending — no live capture yet)

## References

- [PIX: Interactive Animated LED Backpack (Hackster, archived)](https://web.archive.org/web/20210515074642/https://www.hackster.io/news/pix-interactive-animated-led-backpack-d29f09a138c2)
- [Pix Mini crowdfunding press release (PRWeb, 2019)](https://www.prweb.com/releases/pix-mini-the-first-smart-backpack-for-kids-eclipses-crowdfunding-goal-on-day-one-and-surpasses-27-000-in-presales-on-kickstarter-in-first-week-841249079.html)
- [pix.style, archived December 2019](https://web.archive.org/web/20191217051149/https://www.pix.style/)
- [Pix Backpack app listing on Google Play, archived December 2020](https://web.archive.org/web/20201204124920/https://play.google.com/store/apps/details?id=style.pix.app)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md)
- [Firmware Update (DFU / OTA)](../protocols/firmware-update.md)

## Contributors

- Liberated Bread research team — initial app analysis and protocol mapping
