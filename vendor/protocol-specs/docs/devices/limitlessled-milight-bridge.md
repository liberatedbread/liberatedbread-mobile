# LimitlessLED / Mi-Light WiFi Bridge (legacy)

> **Status**: Complete (discovery + transport hardware-verified; command tables from public docs)
> **Protocol**: WiFi (UDP/TCP 8899 legacy byte protocol; UDP 48899 discovery)
> **Manufacturer**: LimitlessLED / Mi-Light (Futlight)
> **Manufacturer Status**: Abandoned

## Overview

The LimitlessLED/Mi-Light WiFi bridge relays LAN commands to 2.4 GHz RF bulbs
(RGB, dual-white, RGBW, RGBW/WW-CW). It was sold 2012–2017 under many brands
(LimitlessLED, Mi-Light, Easybulb, applight, …) and its protocol was published
by the vendor and is now community-maintained prior art. This spec covers the
legacy v1–v5 generation — the one verified live on our LAN — and includes the
v6 ("iBox") layout for recognition only.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | WiFi Bridge v1–v5 (observed unit reports module `HF-LPB130`) |
| Chipset | Shanghai High-Flying WiFi module (HF-LPB1xx) + MCU + PL1176/LT8900-class 2.4 GHz transceiver |
| Radio | WiFi 802.11n (2.4 GHz) + proprietary 2.4 GHz RF to bulbs |
| FCC ID | — |

Observed unit: `192.0.2.194`, MAC `34:EA:E7:AA:BB:CC` (OUI Shanghai
High-Flying), TCP 8899 open, HTTP admin on :80 behind Basic auth.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes (bridge must join home WiFi) |
| Method | `softap_http` |
| Setup AP / advertised name | open AP named `milight*` / `HF-*`; bridge at `10.10.100.254` |
| Passphrase protection | plaintext (web UI form posts; Basic auth with default `admin`/`admin`) |
| Confidence | medium (public vendor docs; not re-run against our unit) |

Join the setup AP, browse to `http://10.10.100.254`, set Work Mode to STA,
choose the home SSID, enter its passphrase (WPA2PSK/AES), restart. Then
rediscover on the home LAN by broadcasting `HF-A11ASSISTHREAD` (or
`Link_Wi-Fi` on older firmware) to UDP 48899 — the reply is a CSV line
`ip,mac,module`.

**Bulb pairing**: power the bulb, then send the target zone's ON command
within ~3 s; the bulb flashes to confirm. Unlink by sending zone ON five times
in the same window. (Public docs; not hardware-verified here.)

**Factory reset**: restore from the module web UI's management page (or the
hardware reset button where exposed); the module falls back to AP mode. Bulb
pairings generally survive. Confidence: low.

**Rebinding to a new network**: possible in place from the web UI, but the
module only hosts its setup AP while it cannot see its configured network —
power-cycle the bridge with the old SSID gone and it falls back to AP mode.

## Protocol Summary

### Discovery (hardware-verified 2026-08-19)

Broadcast ASCII `HF-A11ASSISTHREAD` to UDP 48899 → reply
`192.0.2.194,34EAE7AABBCC,HF-LPB130` from source port 48899. The older probe
`Link_Wi-Fi` got no reply from this unit (its firmware answers only the HF-A11
string). The v6 session handshake on UDP 5987/8899 is **not** answered by this
unit — it is a legacy-generation bridge.

### Legacy commands (v1–v5, port 8899)

Every command is 3 bytes: `<cmd> <arg> 0x55` (`arg` = 0x00 except brightness
and color). No acknowledgements — repeat ~3× with ≥100 ms spacing.

#### RGBW bulbs

| Command | Bytes | Notes |
|---------|-------|-------|
| All on / off | `42 00 55` / `41 00 55` | |
| Zone 1–4 on | `45/47/49/4B 00 55` | |
| Zone 1–4 off | `46/48/4A/4C 00 55` | |
| All white | `C2 00 55` | zone: `C5/C7/C9/CB` |
| Set color | `40 <hue> 55` | wheel starts at violet: 0x00 violet … 0xB0 red … 0xF0 lavender |
| Set brightness | `4E <lvl> 55` | 0x02–0x1B, applies to last-addressed zone |
| Disco cycle / faster / slower | `4D / 44 / 43 00 55` | |
| Night mode | OFF, then `OFF|0x80` ~100 ms later | e.g. `46 00 55` then `C6 00 55` |

#### Dual-white bulbs

| Command | Bytes |
|---------|-------|
| All on / off | `35 00 55` / `39 00 55` |
| Zone 1–4 on / off | `38/3D/37/32` / `3B/33/3A/36` (+`00 55`) |
| Warmer / cooler | `3E 00 55` / `3F 00 55` |
| Brightness up / down | `3C 00 55` / `34 00 55` |

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Web admin; 401 Basic realm `USER LOGIN` (defaults `admin`/`admin` per docs, not tried) |

## Tools Used

- [x] Python UDP/TCP probes against the live bridge (scripts + transcripts held
  in the maintainers' private research workspace, not committed here)
- [x] Public protocol docs (see References)

## References

- [LimitlessLED developer documentation mirror (legacy + v6)](https://github.com/BKrajancic/LimitlessLED-DevAPI/blob/master/LimitlessLed_Dev_Markdown.md)
- [python-ledcontroller (legacy byte tables)](https://github.com/ojarva/python-ledcontroller)
- [Home Assistant limitlessled integration](https://www.home-assistant.io/integrations/limitlessled/)

## Contributors

- Liberated Bread clean-room project — live probe + spec (2026-08-19)
