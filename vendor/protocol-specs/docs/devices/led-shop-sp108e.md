# SP108E WiFi Pixel Controller (LED Shop)

> **Status**: Spec Available (unverified against hardware)
> **Protocol**: WiFi (raw TCP 8189; UDP 8188 during provisioning — no BLE)
> **Manufacturer**: SPLED-family (sold as SP108E by many resellers)
> **Manufacturer Status**: Unsupported

## Overview

The SP108E is a low-cost WiFi controller for addressable (SPI pixel) LED strips —
WS2811, WS2812, SK6812 and similar — driven by the "LED Shop" Android app
(`com.cdc.ledshop`). It is one of the friendliest devices in this catalogue:

- **No cloud, ever.** The app contains zero http(s):// URLs — no account, no OTA,
  no analytics. A vendor shutdown cannot brick it.
- **No BLE.** Control is a small framed binary protocol over raw TCP on port 8189.
- The full command set — framing, handshake, 28 opcodes, 17-byte state sync — is
  documented in `device-specs/devices/led-shop-sp108e.yaml` and corroborated by an
  independent open-source client ([blacklizard/LED-Shop-SP108E](https://github.com/blacklizard/LED-Shop-SP108E)).

The reason it needs rescuing anyway: the vendor app is the only client that speaks
the protocol, and it is version-locked to the Play store. This spec is everything a
replacement client needs.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | SP108E |
| Chipset | STM32F0 drives the LED CLK/data lines (per the Tasmota teardown); Wi-Fi radio unconfirmed (ESP-family suspected from the 192.168.4.1 SoftAP default) |
| Radio | WiFi 802.11n (2.4 GHz) |
| Power | 5–24 V DC input |

## Initial Setup

Out of the box the controller hosts an **open SoftAP** — SSID prefix `SP108E_`,
device at `192.168.4.1`. You can drive it directly from that AP, or provision it
onto your home network.

| Property | Value |
|----------|-------|
| Setup required | Only to join a home network; direct SoftAP control works out of the box |
| Method | `softap_udp` (credentials over TCP 8189, token reply on UDP 8188) |
| Setup AP / advertised name | `SP108E_…` (open, no passphrase) |
| Passphrase protection | Effectively plaintext — per-frame random-key XOR obfuscation, keys sent alongside the data |
| Confidence | medium (recovered from the app; not replayed on hardware) |

Provisioning flow: join the SoftAP → TCP-connect to `192.168.4.1:8189` and bind
local UDP 8188 → send `CMD_CHECK_DEVICE` (0xD5) and expect the keyed reply → send
`CMD_AP_NETWORK_CONFIG` (0x26) with the XOR-obfuscated home SSID/password/token →
wait for the controller's UDP 8188 broadcast (byte 0 = 0x38, bytes 2–5 = device IP,
rest = token) → on token match send `CMD_AP_NETWORK_CONFIG_OK` (0x27). The device
joins your network; find it afterward with a TCP scan of your /24 on port 8189.

**Factory reset**: not established — no documented button procedure. What the app
does expose is a software equivalent: any client on the control channel can send
`CMD_SET_DEVICE_TO_AP_MODE` (0x88), which drops the device back into SoftAP /
provisioning mode with no physical access needed.

**Rebinding to a new network**: in place, if the old network is still up — send
0x88, then re-run the provisioning flow with the new credentials. If the old
router is already gone, power-cycle the controller; devices of this class fall
back to SoftAP when their network disappears (unverified on this unit).

## Protocol Summary

Transport: **raw TCP port 8189** (connect timeout ~1 s, read timeout ~5 s). The
prior public reverse engineering drives the *identical* framing over **UDP 8189**,
so the device most likely listens on both — try TCP first, fall back to UDP.

### Framing

Every command is 6 bytes:

| Offset | Value | Description |
|--------|-------|-------------|
| 0 | `0x38` | START_FLAG |
| 1–3 | nonce / params | Per-frame random bytes chosen by the client (a byte equal to `0x38`/`0x83` is incremented by 1). Up to 3 parameter bytes override these slots in order — max 3 payload bytes per command. |
| 4 | `CMD` | Opcode |
| 5 | `0x83` | END_FLAG |

Handshake commands (`CHECK_DEVICE` 0xD5, `GET_DEVICE_NAME` 0x77) derive a key from
the nonce bytes — `key = ((b2 >> 5) & 7) | (b0 & 0x53) | ((b1 << 2) & 0xFD)` —
which the device echoes in its reply (discovery reply byte 0; AP check reply
byte 5). Most set-commands answer with a single `0x31` ('1') ACK.

### Discovery

No mDNS, no SSDP, no beacon. Scan your subnet: for each host accepting TCP 8189,
send a framed `GET_DEVICE_NAME`; a reply whose first byte equals the derived key
is an SP108E, and the device name follows from byte 1. The keyed reply *is* the
identification.

### Commands

All frames shown with nonce bytes `00 00 00` — any non-flag values work.

| Command | Bytes | Description |
|---------|-------|-------------|
| Check device | `38 00 00 00 D5 83` | Handshake; keyed 6-byte reply |
| Get device name | `38 00 00 00 77 83` | Discovery; reply = key + name |
| Toggle power | `38 00 00 00 AA 83` | **Toggle only** — read sync byte [1] first |
| Sync state | `38 00 00 00 10 83` | Returns 17-byte state block (below) |
| Set mode/effect | `38 MM 00 00 2C 83` | Effect index |
| Auto cycle | `38 00 00 00 06 83` | Auto mode cycling |
| Set speed | `38 VV 00 00 03 83` | |
| Set brightness | `38 VV 00 00 2A 83` | |
| Set white brightness | `38 VV 00 00 08 83` | RGBW strips |
| Set color | `38 RR GG BB 22 83` | Static RGB |
| Set RGB order | `38 VV 00 00 3C 83` | |
| Set IC model | `38 VV 00 00 1C 83` | LED chipset index |
| Set pixel count | `38 HI LO 00 2D 83` | Big-endian (hypothesis) |
| Set segment count | `38 HI LO 00 2E 83` | Big-endian (hypothesis) |
| Set device name | `38 00 00 00 14 83` | Two-step: ACK `0x31`, then raw UTF-8 name |
| Set AP mode | `38 00 00 00 88 83` | Return to SoftAP/provisioning |
| Busy check | `38 00 00 00 2F 83` | reply[0] must be `0x31` |

The full 28-opcode map (custom-effect preview/recode streaming, page change,
record count, password) is in the YAML spec. Custom-effect row streaming
(preview 0x24 / recode 0x4C, up to ~300 rows with per-row `0x31` ACKs) is the one
area **not fully traced** — treat as medium confidence.

### State sync reply (CMD_SYNC, 17 bytes)

| Offset | Description |
|--------|-------------|
| 0 | `0x38` |
| 1 | device on/off |
| 2 | current mode |
| 3 | current speed |
| 4 | brightness |
| 5 | RGB order |
| 6–7 | segment count (big-endian, clamped ≥ 1) |
| 8–9 | second count (big-endian) — LEDs-per-segment vs secondary field **unresolved** |
| 10–12 | adapter RGB |
| 13 | IC model |
| 14 | record/custom count |
| 15 | white brightness |
| 16 | `0x83` |

### Sequencing rules that matter

- Serialize commands with ~200 ms between them.
- While the device reports **off**, most commands are ignored — toggle, name,
  sync, record-num, AP-mode and check-device are the exceptions.
- Power is a toggle: sync first, then toggle only if needed.
- Rename/password are two-step: framed command → `0x31` ACK → raw UTF-8 payload.

## Privacy & security notes

The control port has **no authentication** — anyone on your LAN (or on the open
SoftAP) can drive the controller, including sending the 0x88 back-to-provisioning
command. The provisioning frame carries your Wi-Fi passphrase under trivial XOR
obfuscation. Neither is a reason to avoid the device; both are reasons to keep it
on a network you trust.

## Tools Used

- [x] APK static analysis (jadx) of `com.cdc.ledshop` v1.13.0
- [x] Community open-source implementations (blacklizard, psxde, BlitzKraig)
- [ ] Live capture against hardware (pending — see Open Questions)

## Open Questions

- Does the device still accept **UDP 8189** (matching the blacklizard client)?
- Sync bytes [8:9]: LEDs-per-segment or a secondary segment field?
- Custom-effect row format for preview/recode streaming.
- Where (if anywhere) the two-step device password is later required.

## References

- [blacklizard/LED-Shop-SP108E — independent RE, macOS client](https://github.com/blacklizard/LED-Shop-SP108E)
- [psxde/sp108e-led-controller](https://github.com/psxde/sp108e-led-controller)
- [BlitzKraig/SP108E-control](https://github.com/BlitzKraig/SP108E-control)
- [Tasmota — SP108E hardware teardown](https://tasmota.github.io/docs/devices/SP108E-LED-strip-controller/)
- [LED Shop on Google Play](https://play.google.com/store/apps/details?id=com.cdc.ledshop)

## Contributors

- @blacklizard — first public reverse engineering of the SP108E protocol
