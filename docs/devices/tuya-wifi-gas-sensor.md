# Tuya WiFi Combustible Gas Sensor (rqbj family)

> **Status**: Research — protocol and DP model corroborated across the Smart Life 7.9.0 decompile and community sources; **no hardware verification yet**
> **Protocol**: WiFi (Tuya LAN: UDP 6666/6667 discovery, TCP 6668 control, AES-128-ECB) + TuyaMCU UART inside the device
> **Manufacturer**: Tuya (platform) — the actual sensors are anonymous white-label OEMs (UanTii, SMARSECUR, PGST, LDASEC, Digma DiSense G1, …)
> **Manufacturer Status**: Active (Tuya Inc., NYSE: TUYA; individual OEM brands come and go)

## Overview

This page covers not one product but the high-volume Tuya OEM family of
Wi-Fi combustible-gas alarms — Tuya device **category `rqbj`** — sold under
dozens of white-label names ("Tuya WiFi Natural Gas Leak Detector LPG Leakage
Sensor Sound Alarm & 433MHz Remote Control" and variants). The canonical
representative with a public teardown is the **DY-RQ400A**; a gas + CO combo
variant ("C2 Gas Sensor", protocol 3.4) also exists.

Two facts matter more than everything else on this page:

- **The sensor works as a standalone alarm with no Wi-Fi at all.** A separate
  sensor MCU owns the gas element, buzzer and LEDs, with the trip threshold
  fixed in its firmware (7±3 %LEL CH₄ on the RQ400A, latching). The Tuya
  Wi-Fi module only reports state and accepts configuration.
- **The "433MHz" in the listings is not the control channel.** It's a sub-1GHz
  receiver for pairing cheap RF remotes (silence/self-test) and, on some
  listings, wireless gas-shutoff valves. All app traffic is 2.4 GHz Wi-Fi.

Once the per-device **local key** is known (one-time cloud step), the device
is fully controllable over the LAN forever — no Tuya cloud, no DNS redirect.

> **SAFETY**: this is a life-safety device. Local control must never replace
> its standalone alarm function, and DP 12 (`alarm_switch`) can silence the
> buzzer entirely — treat that toggle with care.

## Hardware

| Property | Value |
|----------|-------|
| Family | Tuya category `rqbj` (combustible gas alarm) |
| Canonical model | DY-RQ400A (Tuya Expo product 602455, productId `13nrj1aeeaqh54cz`) |
| Other known productIds | `stqmzk01tbm3qwhg` (RQ400A-Update, CB2S), `dskjwfinoid46aiw` (C2 gas+CO combo, protocol 3.4) |
| Wi-Fi chipset | Tuya WB2S (Beken BK7231T) or CB2S (BK7231N); WB3S/WBR3 on some clones |
| Sensor MCU | RunJet RJM8L151F6P6 (RQ400A), linked by UART (TuyaMCU serial, 9600 8N1) |
| Radio | Wi-Fi 2.4 GHz 802.11 b/g/n + module BLE (pairing only) + 433MHz RX (remotes/valves, not IP control) |
| FCC ID | None at device level; module certified as 2ANDL-WB2S (grantee: Hangzhou Tuya) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — Tuya pairing (EZ / AP / BLE-assisted), plus one-time local-key extraction for LAN control |
| Method | `smartconfig` (EZ mode), `softap_udp` (AP mode), `ble_provisioning` — all SDK-generic, none replayed on this hardware |
| Setup AP / advertised name | EZ mode: no AP (SmartLink broadcast); AP mode: open `SmartLife-XXXX`-style hotspot (per-clone naming unverified) |
| Passphrase protection | device_encrypted (inside Tuya's pairing exchange; post-setup traffic is AES under the local key) |
| Confidence | medium — generic Tuya SDK behavior confirmed in the Smart Life 7.9.0 decompile; per-clone details unverified |

Pairing is stock Tuya: hold the button ~5 s for fast-blink EZ mode (hold
again for slow-blink AP mode), then add the device in Smart Life or Tuya
Smart. The gas-sensor UI in those apps is a **cloud-delivered React Native
panel** — the APK contains no gas-sensor code at all.

**For local control you need one more step: extract the local key.** Pair the
device, link the app account to a free Tuya IoT developer project, and run
the tinytuya wizard to pull the device id + 16-char local key. This is the
only cloud dependency; Tuya has broken this flow for some account types
before, so verify it works before committing to a local-only install.

**Factory reset**: hold the pairing button ~5 s until the LED enters
fast-blink pairing mode (generic stock-Tuya behavior, low confidence for this
exact family — button placement varies per clone). Clears Wi-Fi credentials
and the cloud binding; the device id / local key pair is reissued on
re-pairing, so **re-extract the local key afterwards**. MCU-side alarm
function and thresholds survive — they never depended on Wi-Fi.

**Rebinding to a new network**: no in-place credential update; factory reset
and re-pair. The old network does not need to be up.

## Protocol Summary

### Tuya LAN protocol (the control plane)

| Layer | Value |
|-------|-------|
| Discovery | UDP broadcast on 6666/6667 — framed datagrams carrying device id, product key, protocol version (3.1/3.3/3.4) |
| Control | TCP 6668 |
| Framing | `0x000055aa` header, seq(4), command(4), length(4), payload, integrity(4), `0x0000aa55` trailer |
| Encryption | AES-128-ECB under the 16-char local key; 3.3 adds a `"3.3"`+padding version prefix and HMAC-SHA256 integrity; 3.4 prepends a session-key handshake (commands 0x03/0x04/0x05) |
| Data model | DPS map, JSON `{"dps": {"<dp>": <value>}}` |

Key message commands: `0x07` CONTROL (set DPs), `0x08` STATUS (push), `0x09`
HEART_BEAT, `0x0a` DP_QUERY (`0x10` on 3.3+), `0x12` UPDATEDPS, `0x13`
CONTROL_NEW. Reference implementation: [tinytuya](https://github.com/jasonacox/tinytuya).

### rqbj datapoints

| DP | Code | Type | Access | Meaning |
|---:|------|------|--------|---------|
| 1 | self-check result | enum | ro | `checking` / `check_success` / `check_failure` / `others` |
| 2 | `gas_sensor_state` | enum | ro | **Gas alarm**: `alarm` / `normal` (MCU-latched; not clearable over Wi-Fi) |
| 3 | `alarm_time` | value 0–180 s | rw | Alarm duration |
| 5 | `gas_sensor_value` | value 0–1000 | ro | Gas level — RQ400A: 0–100 ≈ % of trip point; C2: ppm |
| 6 | `co_state` | enum | ro | CO alarm (combo units) |
| 8 | alarm melody | enum 0–4 | rw | Buzzer melody |
| 9 | self-check trigger | bool | rw | Trigger self-test (result → DP 1) |
| 10 | preheat | bool | ro | Sensor warm-up in progress |
| 12 | `alarm_switch` | bool | rw | Audible buzzer on/off — **safety-relevant** |
| 14 | `muffling` | bool | rw | Silence active alarm once (auto-resets) |
| 20 | `co_value` | value ppm | ro | CO reading (combo units) |

The exact DP set varies per productId — dump a new unit with a tinytuya scan
before trusting the table.

### Inside the box: TuyaMCU UART

The Wi-Fi module and sensor MCU talk TuyaMCU serial (9600 8N1 on the RQ400A).
This matters for the nuclear option: an ESPHome/OpenBeken build flashed onto
the WB2S/CB2S over UART (RX1/TX1 pads, 3.3 V, via ltchiptool) keeps talking
to the untouched sensor MCU — a complete 12-DP ESPHome config for the
DY-RQ400A is published (see References). CloudCutter OTA-flashing works only
on unpatched firmware batches.

## Cloud dependency & keep-alive (Home Assistant users)

- **Tuya cloud status: alive** (actively shipping as of 2026). White-label
  OEMs behind individual clones come and go — that affects firmware support,
  not connectivity.
- **What breaks if the cloud dies**: remote access, the app panel UI, OTA,
  new-device pairing, and local-key extraction for not-yet-extracted units.
  **What keeps working**: everything, locally, for any unit whose local key
  you already have — UDP 6666/6667 and TCP 6668 are plain local sockets, so
  WAN-blocking the device is safe and needs no DNS redirect.
- **Recommended setup**: extract the local key once (tinytuya wizard), then
  integrate via [localtuya](https://github.com/rospogrigio/localtuya) (HACS)
  or [tuya-local](https://github.com/make-all/tuya-local) — the latter ships
  ready-made configs for this family (`rq400a_gasalarm`,
  `digma_disenseg1_gassensor`, `boundless_pa210w_gasalarm`) — and WAN-block
  the device. Record the local key somewhere durable; a factory reset
  reissues it.
- **Automation hygiene for a safety sensor**: treat device-unavailable as a
  fault to alert on; never automate `alarm_switch` (DP 12) off unattended.

## Tools Used

- jadx decompile of Smart Life 7.9.0 (`com.tuya.smartlife`, versionCode 832,
  AppGallery build, SHA-256 `8feefdc4…7acb43`) — confirmed the generic Tuya
  LAN machinery (ports 6666/6667/6668, AES paths, DPS dispatch, SmartLink EZ
  provisioning) and established that no gas-sensor-specific code or Tuya
  endpoint strings exist in the APK
- Source reads of tinytuya, tuyapi, make-all/tuya-local, and the ESPHome
  DY-RQ400A device page

## Open gaps (need hardware)

- Exact clone identity of a given unit: module, MCU, protocol version, real
  DP set (tinytuya scan answers all four).
- 433MHz side: remotes only, or also valve actuators? Is pairing state
  visible in any DP?
- CloudCutter feasibility of shipped firmware batches vs UART-only flashing.
- Does the MCU keep alarming with the Wi-Fi module removed?

## References

- [ESPHome device page — Tuya DY-RQ400A](https://devices.esphome.io/devices/tuya-dy-rq400a-combustible-gas-alarm/) — teardown, DP map, flashing procedure
- [tinytuya](https://github.com/jasonacox/tinytuya) — LAN protocol reference + local-key wizard
- [tuyapi](https://github.com/codetheweb/tuyapi) — independent implementation
- [make-all/tuya-local](https://github.com/make-all/tuya-local) + [issue #2434](https://github.com/make-all/tuya-local/issues/2434) — HA integration, C2 combo cloud model dump
- [housetuya](https://github.com/pascal-fb-martin/housetuya) — independent protocol writeup
- [FCC ID 2ANDL-WB2S](https://fccid.io/2ANDL-WB2S) — module-level certification
- [LibreTiny / ltchiptool](https://github.com/libretiny-eu/libretiny) — BK7231 flashing toolchain
- Machine-readable spec: `device-specs/devices/tuya-wifi-gas-sensor.yaml`

## Contributors

- clean-room research + spec — Smart Life 7.9.0 decompile (2026-08-18), community corroboration
