# Govee RGBIC / DreamColor Lights (segmented)

> **Status**: Spec Available (framing high-confidence; multi-frame layouts app-derived)
> **Protocol**: BLE (+ Wi-Fi variants)
> **Manufacturer**: Govee (Shenzhen Intellirocks Tech / iHoment)
> **Manufacturer Status**: Active

## Overview

Govee's segment-capable light family — RGBIC/DreamColor strips, neon rope,
bulb string lights, TV sync lights, table/floor lamps, car lights and
permanent outdoor lights (well over 80 SKUs; see `device.variants` in the
spec). Every modern SKU uses exactly the same transport: service
`00010203-…-1910`, single characteristic `…2b11` (write + notify, CCCD
0x2902) — there is no per-SKU UUID configuration. This spec is the superset
of the [classic RGB family](govee-rgb-light.md): it adds per-segment
colour, Kelvin colour temperature, timers, multi-packet transfers and the
optional encrypted session layer.

Documented from static analysis of the Govee Home Android app (v7.5.30),
cross-referenced with public RE (egold555/Govee-Reverse-Engineering,
blog.coding.kiwi).

Machine-readable spec: `device-specs/devices/govee-rgbic-light.yaml`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | 80+ SKUs (H6102, H6125–H6127, H6143–H6147, H6171–H6176, H618A–H618F, H619A–H619E, H61xx neon, H70xx/H80xx outdoor, H605x lamps, …) |
| Radio | BLE; most current models are WiFi+BLE |
| Advertised name | `GVH<sku>…`, `GVR…`, `ihoment_H…`, `Govee_…`, `Minger_…`, `GBK_…` |
| Advertised service | `00010203-0405-0607-0809-0a0b0c0d1910` |
| Manufacturer company ID | `0xEC88` (60552), or `0x88XX` when a version byte leads the payload (`0x8802`/`0x8803`/`0x8843` observed 2026-08-22) — match `88 EC` at offset 0 or 1. goodsType (2 bytes BE after the company bytes) identifies BLE-first models (234=H612A–F, 13=H6145–H6147/H6171, …); WiFi-first lights (H6076/H607C/H6099 seen on-air) carry generic `00 01`/`00 02` there — take the model from the `Govee_H<sku>_<mac>` local name |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (some units need the key exchange or AES session layer, below) |
| Method | `ble_direct` |
| Setup AP / advertised name | `GVH<sku>…` (WiFi fallback softAP: `Govee_bulb_<sku>` / `Govee_gateway`) |
| Passphrase protection | plaintext (WiFi models: credentials travel inside the BLE provisioning frame unless the AES session layer was negotiated first) |
| Confidence | high for BLE control; provisioning frame app-derived |

No BLE pairing/bonding for local control: power on, scan, connect, enable
notifications on `…2b11`, write commands. If writes are ignored, the unit
wants the application-layer auth: read `AA B1` for the 8-byte per-device
key (hold the physical button if the returned key looks random — some
models only return the real key while it is held) and authenticate with
`33 B2 <key>` per connection. Many light SKUs never require it.

Newer firmware can instead demand an AES session layer, announced via the
BGC-info characteristic (see below) — a client discovers it rather than
guessing.

**Factory reset**: low confidence, not recovered per model. Mains-powered
models use the generic rapid power-cycle pattern (~5 toggles); many current
models also have a physical button hold (typically 5+ s until a blink). The
confirming signal is a self-initiated blink and re-advertising as
unprovisioned. Clears WiFi credentials and cloud binding on WiFi models.

**Rebinding**: BLE control needs no rejoin. WiFi models rejoin the WLAN via
the BLE provisioning frame (command `0x11` multi-packet write); BLE remains
usable throughout.

## Protocol Summary

**Single frame (20 bytes):** `[0]=0x33` write / `0xAA` read / `0x3A`
write-with-read, `[1]=command`, `[2..18]=payload` zero-padded,
`[19]=XOR(0..18)`. Write ACKs echo the command with payload byte 0 = 0 on
success. Keep-alive `AA 01` every ~2 s (paused during multi-packet
transfers). After connecting, state sync is: write `33 09` (time sync),
then read `AA 23 FF` (timers), `AA 01` (power), `AA 04` (brightness),
`AA 05` (mode).

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00010203-…-1910` | Govee Light Command Service | The shared command profile for every modern light |
| `00010203-…-2b11` | Control Write/Notify (write, write-without-response, notify) | All command, query, multi-packet and notify traffic |
| `00010203-…-2b12` | BGC Info (read), **on service …1910** | Encryption probe: response byte 0 = 1 → version at byte 1; byte 0 = 2 → extended form. Absent = plaintext protocol |
| `00010203-…-1912` | Govee Telink OTA Service | Firmware update channel on Telink-based units (hw version `1.xx.xx`). Not needed for control |
| `00010203-…-2b12` | OTA Data (write, write-without-response), **on service …1912** | Same UUID as BGC Info, different role — the Telink OTA channel |

Beken (`F000FFC0-…`, hw `2.01.xx`) and Freqchip (`02f00000-…-fe00`, hw
`3.xx.xx`) OTA profiles exist on other hardware generations.

### Core command map (`33`/`AA <op>`)

| Opcode | Purpose |
|--------|---------|
| `0x01` | Power: payload `[0]=0/1`. `AA 01` = keep-alive; response byte 1 carries battery band (bits 4–6), charging (bit 3), low-battery (bit 7) on battery models |
| `0x04` | Brightness 0–100 percent |
| `0x05` | Mode — see sub-modes below |
| `0x06` | Firmware version (read; ASCII) |
| `0x07` | Device info: sub `0x02`=UUID, `0x03`=hw, `0x04`=sw, `0x07`=DSP, `0x0A`=MCU sw, `0x0B`=MCU hw |
| `0x09` | Time sync: `[year, month, day, hour, 1, tzHourOffset, tzMinOffset]` — written right after connecting |
| `0x0A` (command) | Legacy single timer `[enable, onH, onM, offH, offM, group, repeat]` |
| `0x0B` | Delay-off `[enable, hours, minutes]`; read returns remaining time too |
| `0x0F` | Segment-count setting |
| `0x11` / `0x12` | Sleep schedule / wake-up schedule |
| `0x14` | Gradual (fade) on/off, BLE-only models; WiFi+BLE models use `33 A3 01/00` |
| `0x23` | Four-slot timer; read with payload `0xFF` returns all four slots |
| `0x40` | IC count / device splicing |
| `0xB1`/`0xB2` | Auth: `AA B1` reads the 8-byte key (possibly button-gated); `33 B2 <key>` authenticates the connection |

### `33 05` sub-modes (payload byte 0 at frame offset 2)

| Sub-mode | Purpose |
|----------|---------|
| `0x02` | Manual color `[R,G,B]` whole-device; white/CCT on RGB-only hardware: `[FF FF FF 01 Wr Wg Wb]` |
| `0x04` | Scene `[id_lo, id_hi]` (built-ins: 1=sunset, 4=movie, 5=date, 7=romantic, 8=blinking, 9=candlelight, 10=breath, 15=snow, 16=dynamic, 21=chase, 22=stream) |
| `0x0A` | DIY apply `[code_lo, code_hi]`; `0x00FE` = most recent upload |
| `0x0B` | Legacy segment color (15 segments): `[R,G,B, 0x00, maskLo, maskHi]`; kelvin variant inserts `[K_hi, K_lo]` before the mask |
| `0x0D` | Color temperature `[R,G,B, K_hi, K_lo, Wr,Wg,Wb]` — Kelvin big-endian uint16 |
| `0x11` | Legacy music `[effect, sensitivity, …]` (16=energy … 19=scroll) |
| `0x13` | Music v1 `[effect, sensitivity, dynamic, fixedColorFlag, R,G,B]`; effects 0=rhythmPower, 1=rhythmSoft, 3=rhythm, 4=spectrum, 5=energy, 6=scroll |
| `0x15` | **Main segment color (RGBIC):** `[0x01, R,G,B, 0×5, segMask…]` (2-byte mask ≤16 segments, bit-packed beyond); kelvin form `[0x01, FF,FF,FF, K_hi,K_lo, tR,tG,tB, mask…]`; 3-color form `[0x05, …]`; per-segment brightness `[0x03, b0..b14]`; brightness+mask `[0x02, …]`; kelvin-only `[0x04, K_hi, K_lo]` |
| `0x16` | Music (library effects): `[effectCode_lo, effectCode_hi, sensitivity]` |
| `0x2C` | color_multi: `[0x03, K_hi, K_lo]` or `[0x04, R,G,B, (K_hi, K_lo)]` |

Ready-made command frames in the spec: power on/off, brightness `0–100`,
`set_color` as `33 05 15 01 R G B 00×4 FF FF 00×5 <xor>` (all-segments
mask), kelvin-only `33 05 15 04 K_hi K_lo …`, scene, music v1, keep-alive
and state queries.

### Multi-packet (`0xA3`) — per-segment writes, DIY upload, scene blobs

Framing V0: start frame `[0xA3, 0x00, 0x00, <totalPacks+2>, <cmd>, 0x00…]`,
data frames `[0xA3, <seq 1..N>, <17 payload bytes>]`, end frame
`[0xA3, 0xFF, <last chunk>]` — every frame still 20 bytes with the XOR
checksum at byte 19. Newer stacks use `0xA4`/`0xA6` with the same layout;
`0xA1`/`0xA2` are the older write/read pair.

- **cmd `0x40`** per-segment strip write: `[count]` then `count` records —
  type `0x00` color `[0x00, numSegs, R,G,B, segIdx…]`, type `0x01`
  brightness `[0x01, numSegs, brightness, segIdx…]`, type `0x02` CCT on
  gradient strips `[0x02, numSegs, K_hi, K_lo, tR,tG,tB, segIdx…]`.
  Segment indices are 0-based, one byte each.
- **cmd `0x02`/`0x04`** DIY upload: `[modeCode, param0, param1, rgbLen=3n,
  R,G,B × n, effLen=2m, (param, value) × m]`; `param0=0xFF` marks the
  effect block present. Activate afterwards with `33 05 0A FE 00`.
- **cmd `0x01`/`0x02`/`0x07`/`0x0A`** "new scenes": the payload is a
  server-generated effect blob (base64 in the cloud scene record) sent
  verbatim — the app does not build these locally, so a clean-room client
  can only replay captured blobs.

### Async notify (`0xEE`)

`frame[0]=0xEE`, `frame[1]=sub-type`, 17-byte payload. Sub-types: `0x11`
WiFi connect status (payload 0 = connected), `0x22` IC count, `0x40`
10-byte device status report, `0x54` movie-feast on/off; detail family
`0x30`: 1=light status, 2=energy saving, 3=battery, 4=music, 5=volume,
6=without-interrupt, 7=sleep.

### Encrypted firmware (app-derived, unverified on hardware)

Newer firmware can demand an AES session layer. Read the BGC-info
characteristic (`…2b12` on service `…1910`); no characteristic = no
encryption. Version 1: 20-byte frames `[0xE7, sub, payload…, xor]` on
`…2b11` — sub `0x01` requests a 16-byte session key, sub `0x02` confirms;
steady-state traffic is AES-128-ECB per 16-byte block with an RC4 tail.
Version 2: AES-128-GCM with an 8-byte IV-key per direction and a 4-byte
big-endian message counter (`counter‖ciphertext‖tag`). Handshake keys are
embedded in the app binary and, per clean-room policy, are not reproduced
here — the spec documents the mechanism only. Most units in the field still
accept plaintext commands.

### WiFi provisioning and LAN API

WiFi onboarding is a BLE write: command `0x11` as a multi-packet transfer,
payload `[ssidLen][ssid][pwdLen (0 if open)][pwd][runMode][tzOffsetHours]
[iotVersion][tzOffsetMinutes]` plus optional Matter/security extensions.
Some bulbs/strings fall back to a softAP (`Govee_bulb_<sku>`,
`Govee_gateway`) hosting a TCP provisioning socket on `192.168.1.1:7200` /
`192.168.4.1:8200` (10-byte `AA 33` header + JSON).

WiFi models can expose Govee's local Wi-Fi (LAN) API (UDP 4001/4002/4003,
JSON `scan`/`devStatus`/`onOff`/`brightness`/`colorwc`/`pt`). That protocol
is device-firmware-side — the app only toggles it with a BLE-protocol frame
(write type `0xE3`, sub `0x01`, payload `0x00/0x01`; read type `0xEA`),
gated on a per-device WiFi function-list bit and minimum firmware versions.
See the Home Assistant `govee_light_local` integration.

## Tools Used

- [ ] Static analysis of the Govee Home Android app v7.5.30 (jadx)
- [ ] egold555/Govee-Reverse-Engineering, blog.coding.kiwi GATT dump, chvolkmann/govee_btled (cross-references)

## References

- [egold555/Govee-Reverse-Engineering](https://github.com/egold555/Govee-Reverse-Engineering)
- [Reverse-engineering Govee smart lights](https://blog.coding.kiwi/reverse-engineering-govee-smart-lights/)
- [chvolkmann/govee_btled](https://github.com/chvolkmann/govee_btled)
- [Home Assistant Govee lights local integration](https://www.home-assistant.io/integrations/govee_light_local/)

## Contributors

- @kimi - spec from app static analysis + third-party RE sources
