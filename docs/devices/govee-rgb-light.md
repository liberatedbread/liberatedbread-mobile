# Govee RGB Lights (classic, non-segmented)

> **Status**: Spec Available (core protocol high-confidence; per-model list app-derived)
> **Protocol**: BLE (+ Wi-Fi variants)
> **Manufacturer**: Govee (Shenzhen Intellirocks Tech / iHoment)
> **Manufacturer Status**: Active

## Overview

Govee's plain-RGB light family: bulbs (H6071/H6075, H6085/H6086/H6089,
H60A0), non-segmented strips (H6110, H614B/H614E, H6159, H6160, H6178), car
lights (H6114, H6118, H6194) and assorted older strips. All speak the
shared Govee 20-byte BLE protocol on service `00010203-…-1910`,
characteristic `…2b11` (write and notify on the same characteristic).
"Classic" means color is whole-device only — there are no per-segment
commands; units that report segment support instead answer the extended
commands in [Govee RGBIC / DreamColor Lights](govee-rgbic-light.md), which
is the superset spec.

Documented from static analysis of the Govee Home Android app (v7.5.30),
cross-referenced with chvolkmann/govee_btled and
egold555/Govee-Reverse-Engineering.

Machine-readable spec: `device-specs/devices/govee-rgb-light.yaml`.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | ~30 SKUs; see `device.variants` in the spec for the per-model list |
| Radio | BLE; many members (H6085/H6086/H6089 bulbs, H61xx strips) are WiFi+BLE |
| Advertised name | `GVH6…`/`GVH7…` (modern), `ihoment_H6…`/`ihoment_H7…` (legacy), `Govee_H…`, `Minger_H…` — both sku ranges this spec covers, in each of the four name forms (low confidence per form) |
| Advertised service | `00010203-0405-0607-0809-0a0b0c0d1910` (presence in the ADV packet varies by model, unverified for most) |
| Manufacturer company ID | `0xEC88` (60552), or `0x88XX` when a version byte leads the payload — match `88 EC` at offset 0 or 1. goodsType (2 bytes BE after the company bytes) distinguishes BLE-first models (57=H6071, 67=H6075, 188=H60A0, …); WiFi-first models carry generic values there and are named by the local name |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No (a minority of units need a button-gated key exchange, below) |
| Method | `ble_direct` |
| Setup AP / advertised name | `GVH6…` |
| Passphrase protection | plaintext (WiFi models: SSID/passphrase travel inside the BLE provisioning frame, unbonded) |
| Confidence | high for BLE control (no pairing); provisioning flow app-derived |

No BLE pairing/bonding for local control: power on, scan, connect, write to
`…2b11`. A minority of units demand an application-layer key exchange:
`AA B1` reads an 8-byte per-device key (some models only return the real
key while the physical button is held, as on the
[H5080 plug](govee-h5080-plug.md)), and the connection then authenticates
once with `33 B2 <key>`. Most lights in this family skip auth entirely.
Newer firmware may instead require the AES session handshake documented in
the [RGBIC spec](govee-rgbic-light.md) — the device announces this through
the BGC-info characteristic, so a client discovers it rather than guessing.

WiFi onboarding is optional and only needed for cloud / LAN-API use: it is a
BLE provisioning write (shared frame documented in the RGBIC spec); the
bulbs additionally fall back to a softAP (`Govee_bulb_<sku>`) hosting a TCP
provisioning socket on `192.168.1.1:7200`.

**Factory reset**: low confidence, not recovered per model. Rapid power
cycling (~5 toggles, a second in each state) is the generic pattern for
mains-powered Govee lights; WiFi models additionally have an in-app restore
path. The confirming signal is a self-initiated blink and re-advertising as
unprovisioned — if the light just comes back on unchanged, try three
cycles. Clears WiFi credentials and cloud binding on WiFi models.

**Rebinding**: BLE control needs no rejoin. WiFi models rejoin the WLAN via
the BLE provisioning write; BLE remains usable throughout.

## Protocol Summary

20-byte fixed frames: `[0]=0x33` control / `0xAA` query, `[1]=command`,
`[2..18]=payload` zero-padded, `[19]=XOR(0..18)`. Write ACKs echo the
command id with payload byte 0 = 0 on success. Keep-alive `AA 01` every ~2
s while connected; after connecting, state is synced with `AA 01` (power),
`AA 04` (brightness), `AA 05` (mode). Unsolicited `0xEE` notify frames
report async events (WiFi connect status, device status report); `0x30`
detail notifies cover light status, battery and music.

### BLE Services

| UUID | Name | Description |
|------|------|-------------|
| `00010203-…-1910` | Govee Light Command Service | Shared command profile across Govee lights |
| `00010203-…-2b11` | Control Write/Notify (write, write-without-response, notify; CCCD 0x2902) | All control and query traffic |

### Commands

| Packet | Purpose |
|--------|---------|
| `33 01 01 00×16 33` / `33 01 00 00×16 32` | Power on / off |
| `33 04 <0–100> 00×16 <xor>` | Set brightness (percent; the H6001 legacy bulb is the exception with a raw 0–255 wire value) |
| `33 05 02 <R> <G> <B> 00×13 <xor>` | Whole-device RGB (manual mode) |
| `33 05 02 FF FF FF 01 <Wr> <Wg> <Wb> 00×9 <xor>` | White / color temperature via the vendor's fixed Kelvin→RGB shade table (app range 1000–10000 K; no Kelvin value crosses the link). A color+white mix form `…R1 G1 B1 01 R2 G2 B2…` also exists |
| `33 05 04 <id_lo> <id_hi> 00×14 <xor>` | Built-in scene (16-bit LE id; seen in the app: 1=sunset, 4=movie, 5=date, 7=romantic, 8=blinking, 9=candlelight, 10=breath, 15=snow, 16=dynamic, 21=chase, 22=stream) |
| `33 05 11 <effect> <sensitivity> …` | Legacy music mode: effects 16=energy, 17=rhythm, 18=spectrum, 19=scroll; the latter three add `[dynamic, colorFlag, R, G, B]` (colorFlag 0 = use the fixed RGB) |
| `33 05 0A <code_lo> <code_hi> 00×14 <xor>` | Apply a stored DIY effect (code `0x00FE` = most recently uploaded) |
| `AA 01 00×17 AB` | Keep-alive / power query; response byte 0 = power, byte 1 = battery/charge bits on battery models |
| `AA 04 00×17 AE` | Query brightness (0–100) |
| `AA 05 00×17 AF` | Query mode: payload byte 0 = sub-mode (`0x02` color, `0x04` scene, `0x0A` DIY, `0x11` music), remainder = sub-mode state |

### Wi-Fi variants

Some firmware exposes Govee's local Wi-Fi (LAN) API once enabled in the
app — the toggle is a BLE-protocol frame (write type `0xE3`, sub `0x01`,
payload `0x01`) and the LAN protocol itself (UDP 4001/4002/4003, JSON) is
firmware-side. See the Home Assistant `govee_light_local` integration.

## Tools Used

- [ ] Static analysis of the Govee Home Android app v7.5.30 (jadx)
- [ ] chvolkmann/govee_btled, egold555/Govee-Reverse-Engineering, blog.coding.kiwi GATT dump (cross-references)

## References

- [chvolkmann/govee_btled](https://github.com/chvolkmann/govee_btled)
- [egold555/Govee-Reverse-Engineering](https://github.com/egold555/Govee-Reverse-Engineering)
- [Reverse-engineering Govee smart lights](https://blog.coding.kiwi/reverse-engineering-govee-smart-lights/)
- [Home Assistant Govee lights local integration](https://www.home-assistant.io/integrations/govee_light_local/)

## Contributors

- @kimi - spec from app static analysis + third-party RE sources
