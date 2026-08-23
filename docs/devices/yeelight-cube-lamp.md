# Yeelight Cube Smart Lamp

> **Status**: Baseline LAN protocol from the vendor's published spec; cube-specific commands from community reverse engineering; nothing replayed against hardware here
> **Protocol**: WiFi (JSON-RPC style over TCP 55443; SSDP-like discovery on 239.255.255.250:1982) + Matter (BLE commissioning)
> **Manufacturer**: Qingdao Yeelink Information Technology Co., Ltd. (Yeelight)
> **Manufacturer Status**: Active (company alive and shipping; cloud optional)

## Overview

The Yeelight Cube Smart Lamp ("Light Gaming Cube") is a modular, stackable
RGB LED lamp system: a powered base with a touch-button control box, plus
stackable 5x5 matrix add-on modules. It is **Matter-certified** and also
speaks Yeelight's published **LAN inter-operation protocol** on TCP 55443 —
two fully local control paths, so the lamp does not depend on the Yeelight
cloud for anything past initial provisioning and firmware updates.

!!! note "What this page is based on"
    The acquired companion app (com.yeelight.cherry **v3.5.4**, sha256
    `c5ca5a5e…8fc7`) contains **no cube code at all** — no `cube`/`YLFWD`
    strings, no Matter stack; cube device UIs are server-driven webviews.
    The baseline protocol section therefore follows the vendor's public
    [inter-operation spec](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf),
    and the cube-specific per-segment/per-pixel commands are
    **community-sourced** (forum + open-source drivers), marked as such
    throughout. The cube's exact LAN `model` string is still unconfirmed.

!!! warning "Not the Cube Lite"
    The **Yeelight Cube Lite** (single 5x20 panel, model family
    `yeelink.light.clt*` — `clt6pro`, `clt4`) is different hardware. This
    page covers the modular `YLFWD-0007/8/9/10` system only.

## Hardware

| Property | Value |
|----------|-------|
| Model Numbers | `YLFWD-0008` (SPOT base, 1x1 spotlight), `YLFWD-0009` (PANEL base, 5x5 diffused), `YLFWD-0010` (MATRIX base, 5x5 clear), `YLFWD-0007` (MATRIX add-on, no base) |
| Chipset | Unknown (Cube-Lite-class Yeelink devices are typically ESP32-based; no teardown located) |
| Radio | Wi-Fi 2.4 GHz (2412–2472 MHz) + BLE (2402–2480 MHz, provisioning/Matter commissioning only) |
| Power | 12 V DC; 0.21 A / 2.5 W (1 module) → 0.8 A / 10 W (4 modules) |
| Expansion | Manual: "maximum expandable quantity 4pcs"; community reports up to 6 (unverified) |
| FCC ID | Not located for the YLFWD models (open question) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `ble_provisioning` (standard Matter commissioning) or `cloud_account` (vendor app) |
| Setup AP / advertised name | Uncommissioned Matter device over BLE; Matter QR on the dock |
| Passphrase protection | device_encrypted (Matter SPAKE2+ session) on the Matter path |
| Confidence | low (neither path replayed; the acquired app can't manage the cube) |

The **Matter path needs no Yeelight account**: commission the lamp with any
Matter controller (Google Home, Apple Home, Home Assistant) using the QR
code on the dock. The vendor-app path exists but the app build audited here
cannot drive it, so which current app manages the cube is an open question.
Whether TCP 55443 needs an explicit "LAN control" toggle on cube firmware is
likewise unverified — community drivers connect directly, suggesting the
port is open on at least some firmware.

**Factory reset**: **not recovered**. The manual text available did not
yield a procedure and the app has no cube code to read one from. Candidates,
both unverified: a long-press on the control-box touch button, or Matter's
"remove from all fabrics" in the ecosystem app (which may leave Wi-Fi
credentials behind).

**Rebinding to a new network**: unverified. Until a reset procedure is
confirmed, assume a router change may require re-commissioning from scratch,
and decommission the lamp from any Matter fabric **before** retiring the old
network.

## Protocol Summary

### Discovery

M-SEARCH multicast to `239.255.255.250:1982` with `ST: wifi_bulb`. The reply
carries the whole identity in **headers** — `Location: yeelight://<ip>:55443`
plus `id`, `model`, `fw_ver`, `support`, `power`, `bright`, `color_mode`,
`ct`, `rgb`, `hue`, `sat`, `name`. `id` is the stable identity; `support` is
the capability list (on matrix units it is reported to include
`set_segment_rgb` and `update_leds`). Cube-family devices also announce
`_miio._udp.local.` as `yeelink-light-<model>-0x<did>`; the modular cube's
exact model string is unconfirmed, and whether it answers miio on UDP 54321
is an open question.

### Framing

Single-line JSON documents terminated by `\r\n`, both directions, on TCP
55443. Requests `{"id":N,"method":"<name>","params":[...]}`; replies echo the
`id` with `result` or `error`; the lamp pushes
`{"method":"props","params":{...}}` on state change. No authentication once
LAN control is on. Rate limit ~60 commands/minute unless music mode
(`set_music`) is active — music mode points the lamp at a client UDP socket
and is what matrix drivers use when streaming frames.

### Commands (standard, vendor-documented)

| Method | Meaning |
|---|---|
| `get_prop` | Property poll; reply array is **positional** (lines up with the request order). `support` returns the capability list. |
| `set_power` / `toggle` | On/off (`["on","smooth",500]`) / flip. |
| `set_bright` | Brightness 1–100 %. |
| `set_rgb` | 24-bit RGB as one int (`R<<16\|G<<8\|B`). |
| `set_hsv` | Hue 0–359, saturation 0–100. |
| `set_ct_abx` | Colour temperature (cube K-range unverified; classic range 1700–6500). |
| `start_cf` / `stop_cf` / `set_scene` / `set_default` | Colour flows, scenes, power-on default. |
| `set_music` | Music mode: `[1,"<host>",<port>]` opens the high-rate UDP channel; `[0]` exits. |

### Commands (cube-specific — COMMUNITY-SOURCED, not vendor-documented)

| Method | Meaning |
|---|---|
| `set_segment_rgb` | Flat int array of 24-bit colours, **5 entries per 5x5 module** (one per row), row-major across the stack. Forum example: `[255,16743680,0,0,16711680]` → row 1 blue, row 2 orange, rows 3–4 off, row 5 red. SPOT (1x1) semantics unknown. |
| `activate_fx_mode` | `params:[{"mode":"direct"}]` — required before per-pixel control; re-send periodically (effectively per frame). |
| `update_leds` | `params:["<base64>"]` — each LED is 3 raw bytes R,G,B → base64 (4 chars) per LED, concatenated; 25 LEDs (75 bytes → 100 chars) per module, row-major. No response in FX mode. **Per-LED brightness beyond RGB is unsolved** (open question). |

## Cloud Dependency & Keep-Alive (Home Assistant users)

The Yeelight cloud is **alive** (checked 2026-08-18) but **optional**
(`cloud.required: false` in the spec):

- **Keep working without it**: all control — power, colour, scenes, music
  mode, and the community per-pixel commands — over LAN 55443; plus the
  whole Matter path through any local controller.
- **Dies with the cloud**: vendor-app provisioning (Matter commissioning
  survives), firmware updates, and the server-driven device UI /
  effect-store pages (`page-*.yeelight.com`).

Keep-alive guidance: **no keep-alive needed**. Block the lamp from the
internet at the router if you like — local control is unaffected. Do enable
LAN control while the app/cloud path still works (in case your firmware
requires the toggle), and prefer Matter commissioning for new setups so the
Yeelight account is never in the loop. In Home Assistant, the core
`yeelight` integration covers basic on/off/colour;
[YeelightMatrix](https://github.com/VladFlorinIlie/YeelightMatrix) adds the
full per-pixel matrix with a painter card. Firmware stockpiling is not
currently possible: the public OTA metadata endpoint answers anonymous
queries with a default non-cube document.

## References

- [Yeelight Wi-Fi Light Inter-Operation Specification (vendor PDF)](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf)
- [Yeelight forum — CubeMatrix: set_segment_rgb parameters](https://forum.yeelight.com/t/topic/33649)
- [VladFlorinIlie/YeelightMatrix](https://github.com/VladFlorinIlie/YeelightMatrix) — per-pixel driver + HA integration
- [danielp370-msft/yeelight-cube](https://github.com/danielp370-msft/yeelight-cube) — modular-cube per-pixel control
- [Max-src/yeelight-cube-lite](https://github.com/Max-src/yeelight-cube-lite) and [fetinin/cubik](https://github.com/fetinin/cubik) — Cube Lite family
- [Home Assistant Yeelight integration](https://www.home-assistant.io/integrations/yeelight/)

Machine-readable spec: `device-specs/devices/yeelight-cube-lamp.yaml`

## Contributors

- Automated research + spec authoring, 2026-08 — app acquisition/static
  audit (com.yeelight.cherry 3.5.4, sha256
  `c5ca5a5e353c0c4ad2ed44dff1e7c5d7635b19b11dbe7566ca5d3cc60f9d8fc7`),
  community-source synthesis. No hardware verification yet.
