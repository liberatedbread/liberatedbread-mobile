# BanlanX / Sperll SP6xxE LED Controllers

> **Status**: In Progress
> **Protocol**: BLE (Wi-Fi provisioning on dual-mode models)
> **Manufacturer**: SPLED (BanlanX) / Shenzhen Sperll Optoelectronic
> **Manufacturer Status**: Active (closed protocol)

## Overview

The SP6xxE family is a line of addressable-pixel (SPI) and analogue (PWM) LED strip
controllers — SP601E through SP64xE — sold under the BanlanX/Sperll brand and
driven by the **SceneX** app (`com.spled.scenex`). All of them are controllable
locally over BLE with no account and no cloud; the vendor cloud
(`app.ledhue.com`) only adds remote control, Alexa linking and firmware updates.

The family is already reverse engineered by the open-source
[UniLED](https://github.com/monty68/uniled) Home Assistant integration, whose five
BanlanX modules are the primary citation for everything on this page. What is
**new** here: SceneX 3.3.2 adds an authenticated BLE channel ("ELS") on recent
firmware that UniLED does not cover — see [Open Questions](#open-questions).

!!! note "One app, five frame formats"
    Every model uses the same GATT service (`0xFFE0`) and characteristic
    (`0xFFE1`), but the frame format depends on the model generation. Identify
    the model — from its manufacturer-data advertisement or a status query —
    before choosing a command set.

| Models | Role | Frame format |
|--------|------|--------------|
| SP601E | 2ch SPI RGB, music | `AA <op> <len> <payload…>` |
| SP602E / SP608E | 4ch / 8ch SPI RGB, music | `88 <op> <len> <payload…>` |
| SP611E / SP617E / SP620E / SP621E | SPI/PWM ("v2") | `A0 <op> <len> <payload…>` |
| SP613E / SP614E / SP623E / SP624E | SPI/PWM ("v3") | `<op> <len> <payload…>` (no header) |
| SP630E | reconfigurable SPI/PWM combo | `53 <cmd> <key> 01 00 <len> <payload…>` |
| SP631E–SP63AE / SP641E–SP64AE | single-function SPI or PWM | same `53` frame as SP630E |

SP63xE models are BLE-only; SP64xE are the dual-mode (BLE + Wi-Fi) counterparts
of the same eleven functions.

## Hardware

| Property | Value |
|----------|-------|
| Models | SP601E/602E/608E, SP611E/613E/614E/617E/620E/621E/623E/624E, SP630E–SP63AE, SP641E–SP64AE |
| Chipset | Custom firmware on a generic BLE SoC (no chip-vendor SDK in the app) |
| Radio | BLE; 2.4 GHz Wi-Fi on SP64xE dual-mode models |
| LED support | WS2812-family pixels (SPI models) and analog PWM strips (mono/CCT/RGB/RGBW/RGBCCT) |
| Audio | Built-in mic music-reactive modes; aux/player inputs on some models |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No for BLE control (all models) |
| Method | `ble_direct`; optional `softap_http`-style Wi-Fi provisioning on SP64xE |
| Setup AP / advertised name | Device SoftAP at `192.168.4.1` (2.4 GHz only) during Wi-Fi config |
| Passphrase protection | not_applicable (BLE); Wi-Fi handoff protection undocumented |
| Confidence | medium (BLE path per UniLED + app; SoftAP flow from app strings only) |

BLE-only models advertise as soon as they are powered and accept a connection
from any central — no account, no PIN, no bonding on legacy firmware. Dual-mode
SP64xE units optionally receive Wi-Fi credentials through their own hotspot
during the app's network-configuration flow; local BLE control never requires
this.

**Factory reset**: not documented for this family. BLE models store no
credentials, so there is nothing to clear — power-cycling drops the current
connection, which is also the remedy for the common failure mode of the
controller already being connected to another phone. On SP64xE units a reset
would clear the stored Wi-Fi credentials; the physical procedure is unknown.

**Rebinding to a new network**: BLE models bind to nothing — just connect from
the new controller (remove the OS-level Bluetooth entry on the old phone first,
so it stops auto-reconnecting and holding the single link). For SP64xE Wi-Fi,
re-run the SoftAP provisioning flow against the new network; no evidence the old
network needs to be online.

## Protocol Summary

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `0000ffe0-0000-1000-8000-00805f9b34fb` | BanlanX LED Control | Primary service on all models |
| `0000ffe1-0000-1000-8000-00805f9b34fb` | Control | Write-without-response commands + status notifications |
| `5833ff01..04-9b8b-5191-6142-22a4536ef123` | ELS vendor characteristics | New authenticated channel in SceneX 3.3.2 — **unmapped**, see Open Questions |

### Discovery

| Signal | Meaning |
|--------|---------|
| Manufacturer data, company id `0x5053` ("SP" LE) | BanlanX/SPLED family member |
| …payload `[model_id, 0x10]` | SP63xE/SP64xE; model_id `0x1F`–`0x35` identifies the exact model (`0x1F` SP630E … `0x35` SP64AE) |
| …other first bytes (`0x01`, `0x02`, `0x05`, `0x17`, `0x1B`…) | Older families (SP601E, SP602E, SP608E, SP617E, SP620E per UniLED) |
| Service `0xFFE0` advertised | Command service present |

### SP6xxE commands (SP630E, SP63xE/SP64xE)

Frame: `53 <cmd> <key> 01 00 <len> <payload…>`. `key` is `0x00` for plaintext;
a nonzero key marks an encrypted payload (unsupported by UniLED — drop, don't
parse). Written verbatim to `0xFFE1`.

| Command | Bytes | Description |
|---------|-------|-------------|
| State query | `53 02 00 01 00 01 01` | Status returns as notification, cmd `0x02` |
| Power on / off | `53 50 00 01 00 01 0X` | X = 1 on, 0 off |
| Brightness | `53 51 00 01 00 02 W LL` | W: 0 color / 1 white level |
| Static RGB + level | `53 52 00 01 00 04 RR GG BB LL` | Static modes |
| RGB color | `53 57 00 01 00 03 RR GG BB` | Dynamic/sound modes |
| Mode + effect | `53 53 00 01 00 02 MM EE` | Mode 1–7 (static/dynamic/sound × color/white, custom) |
| CCT | `53 60 00 01 00 02 CC WW` | Cold/warm (`0x61` in static modes) |
| Effect speed / length | `53 54 … VV` / `53 55 … VV` | |
| Direction / loop / play | `53 56 …` / `53 58 …` / `53 5D …` | |
| Audio input / gain | `53 59 …` / `53 5A …` | Gain 1–16 |
| On/off animation | `53 08 00 01 00 05 01 EE SS PH PL` | Effect 1–4, speed 1–3, pixels 1–600 BE |
| Power-restore | `53 0B … MM` | 0 off / 1 on / 2 last state |
| Coexistence | `53 0A … XX` | Drive SPI + PWM simultaneously |
| Chip order | `53 6B … OO` | RGB order index |
| Light type (SP630E) | `53 6A 00 01 00 02 01 TT` | **Advanced** — re-maps output hardware |

The ~53-byte status payload carries the firmware version string, the light-type
config byte (decode this first — it selects SPI/PWM and channel count), power,
mode, effect, color/white levels, speed/length/direction, audio gain/input and
more; the full offset table is in the machine-readable spec
(`device-specs/devices/banlanx-sp6xxe.yaml`).

### SP601E commands

Frame: `AA <opcode> <len> <payload…>`. Channel byte addresses one output
(master = channels−1 per UniLED).

| Command | Bytes | Description |
|---------|-------|-------------|
| State query | `AA 2F 00` | Reply: `53 43`-flagged multi-packet notification |
| Power | `AA 22 02 CH 0X` | Per channel |
| Brightness | `AA 25 02 CH LL` | |
| Static RGB | `AA 29 05 CH RR GG BB FF` | Trailing `FF` fixed |
| Effect | `AA 23 02 CH EE` | `0x19` solid, `0x01`–`0x18` dynamic, `0x65`–`0x74` sound |
| Effect speed | `AA 26 02 CH SS` | 1–10 |
| Scene | `AA 2E 01 NN` | Recall scene 1–9 |

The SP602E/608E (`0x88` header), "v2" (`0xA0` header) and "v3" (headerless)
families follow the same shape with their own opcode maps — see the UniLED
modules `banlanx_60x.py`, `banlanx2.py`, `banlanx3.py`.

### OTA and cloud

Firmware updates are a custom BLE OTA (no Nordic DFU service). The app checks
`https://app.ledhue.com/spiot/device/check-update`, which returns the firmware
download. No firmware is mirrored here — query the endpoint on your own unit.

## Open Questions

- **ELS authenticated channel (new in SceneX 3.3.2).** Four vendor
  characteristics `5833ff01–04-…` carry a connect-time auth handshake and an
  encrypted session backed by `https://app.ledhue.com/spiot/els/v1`. Cipher and
  message format unknown, and — critically — whether new firmware *requires* it
  or still accepts the legacy plaintext framing is untested. Needs an HCI snoop
  of a first-pairing session on a recent SP63xE/SP64xE.
- All command bytes on this page are community-sourced (UniLED), not captured by
  this project — spot-verify on hardware.
- Roles of `0000ff12/ff14/ff15` (likely an accessory/remote family) and of each
  `5833ff0x` characteristic.
- SoftAP provisioning exchange and the on-Wi-Fi control path of SP64xE models
  (local or cloud-relayed?).

## Tools Used

- [x] Community open-source implementation (UniLED, five BanlanX modules)
- [x] APK static analysis (SceneX 3.3.2 — jadx + Dart snapshot strings)
- [ ] HCI snoop of ELS first-pairing (pending — highest priority)
- [ ] Live capture of command set + SoftAP provisioning

## References

- [UniLED (HACS) — primary protocol citation](https://github.com/monty68/uniled)
- [uniled `banlanx_6xx.py` — SP630E/SP6xxE frame, model table, status layout](https://github.com/monty68/uniled/blob/master/custom_components/uniled/lib/ble/banlanx_6xx.py)
- [SceneX on Google Play](https://play.google.com/store/apps/details?id=com.spled.scenex)
- [BanlanX vendor FAQ/documentation](https://document.ledhue.com/banlanx/faq/version/8/default)

## Contributors

- @monty68 — UniLED Home Assistant integration (BanlanX protocol decoding)
