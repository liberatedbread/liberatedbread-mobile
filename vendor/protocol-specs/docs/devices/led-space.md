# LED space Wi-Fi LED Screen (YSP-001 family)

> **Status**: Complete (app-analysis based; no hardware capture in this project)
> **Protocol**: Wi-Fi (device AP, UDP 9090) + BLE variant
> **Manufacturer**: LOY SPACE / popled.cn
> **Manufacturer Status**: Active (LED space app itself stale since 2023)

## Overview

Wi-Fi-controlled programmable LED screens marketed as **YSP-001** — backpack
screens, advertising vests, LED clothing and dynamic bags. Driven by the
**LED space** app (`com.yj.led`, iOS id 1431362600). Static analysis of the
app confirms this is a **third app binding on the LOY SPACE / popled.cn
platform** already documented for the [AUTOBABA LED Backpack](autobaba-led-backpack.md)
and [NYAN BT Image Controller](nyan-bt-image-controller.md): identical GATT
UUIDs, identical JSON command vocabulary serialized to binary TLV by the same
native library, popled.cn backend hosts throughout.

The same board family ships in Wi-Fi and Bluetooth variants; the app drives
both. The Wi-Fi path is the interesting one here — it is fully local
(device-hosted AP, no account) and needs no new reverse engineering beyond
what the app itself reveals.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | YSP-001 (product listings; `dev_model` default `"gy"` in app) |
| Display | Full-color LED matrix; default geometry 64x64, 160x32 also seen; round panels carry `"CXB5"` in the model string |
| Chipset | Unknown (ESP-style AP behavior on Wi-Fi units) |
| Radio | Wi-Fi (device AP) or BLE, per board variant |
| FCC ID | Unknown |

## Initial Setup

No provisioning is required for AP-mode control — the panel permanently hosts
its own hotspot. See [Initial Device Setup](../protocols/device-setup.md); the
machine-readable spec mirrors this in `device.setup`.

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `softap_udp` (device-hosted AP, UDP control) |
| Setup AP / advertised name | SSID starts with `YS` |
| Passphrase protection | plaintext (AP password; default `12345678` per the app's own help text) |
| Confidence | medium (from decompiled app; not replayed against hardware) |

**Factory reset**: no account or owner binding exists to clear. Content can be
wiped with the platform command `{"cmd":{"delete":{"del_all":1}}}`; a power
cycle restores the AP. If the AP password was changed from the default and
lost, no software recovery path is documented — check the unit for a hardware
reset button. Confidence: low.

**Rebinding to a new controller**: trivial — join the device AP from the new
client and re-run UDP discovery. Nothing ties the panel to a network or owner.
The app does contain a station-mode provisioning command (`param_wifi` set
with `user`/`pwd`/`ip_svr`/`port_svr`/`sec_hb`) that can move the panel onto a
home network pointed at a server; that path is not needed for local control
and its post-provisioning behavior has not been captured.

## Protocol Summary

### Wi-Fi Control Path

1. Join the device hotspot (SSID starts with `YS`, default password `12345678`).
2. Broadcast the TLV serialization of `{"cmd":{"get":"dev_info"}}` to
   `255.255.255.255:9090`. The same probe documented for the AUTOBABA backpack
   (`aa 55 ff ff 08 00 01 00 c1 03 0a 00 d4 03`) applies.
3. The device replies with `{"ack":{"dev_info":{id_dev, model, version, ...}},"sno":N}`;
   the app adopts the reply sender's address (expected to be the AP gateway
   `192.168.4.1`, though the app does not hardcode it).
4. All further commands go unicast to the learned address on UDP port 9090.

Transport details (from `UDPBuild.java` / `PacketDateUtils.java` /
`Constant.java` in com.yj.led): each datagram chunk carries an outer u16-LE
length prefix; large sends split into 180-byte chunks (`writeFscNum`; 120 on
the `writeNum` path) at ~5 ms intervals; sequence numbers start at
4294901761; the app resends up to 10 times at 8 s intervals until an ACK with
the expected `sno` arrives; error replies are `{"cmd":"err"}` /
`{"cmd":"failed"}`.

### Packet Format

Same 0xAA55-framed binary TLV as the BLE path — see the
[AUTOBABA doc](autobaba-led-backpack.md#packet-format). JSON is the
app-internal command form; `libys_parse_tlv.so` (`parseJson`/`parseBin`)
serializes it to the wire and decodes replies.

### Commands

The shared LOY SPACE vocabulary (`power`, `light` 0–15, `get dev_info`,
`delete del_all`, `rotate`, `pgm_play` with the 60-slot `ids_pro` array)
applies; see the AUTOBABA doc. Commands first seen in the LED space app:

| Command | JSON | Description |
|---------|------|-------------|
| Get screen params | `{get:"param_dev"}` | Screen geometry / model |
| Get Wi-Fi params | `{get:"param_wifi"}` | Wi-Fi configuration |
| Set Wi-Fi params | `{param_wifi:{type:0,user:...,pwd:...,ip_svr:...,port_svr:"9090",sec_hb:30}}` | Station-mode provisioning |
| Dispatch program | `{dispatch:{type:1,id_pro:N,play_fixed_time:32767}}` | Play one program for a fixed time |
| Show flag | `{get:"show_dev"}` / `{show_dev:N}` | Device show flag |
| Program flicker | `{pgm_flicker:{type:0,count_pgm:N,time:T}}` | Cycle through programs |
| Bluetooth control | `{bluetooth:{type:0,val:N}}` / `{get:"bluetooth"}` | Radio control |
| Set time | `{timing:"<timestamp>"}` | Device RTC |
| Delete by id | `{delete:{del_ids:[...]}}` | Delete specific programs |

Program upload uses the `pkts_program` JSON structure: `property_pro`
(width/height/gray/type_color), `list_region` geometry, and `list_item`
entries of type `text_pic` (text/color/font) or `graphic` carrying a
`zip_bmp` payload — a zlib-compressed 24-bit BMP rendered app-side. App
templates use `id_pro` 11–19; the platform supports 60 sparse program slots.

### BLE Variant

Identical GATT surface to the AUTOBABA backpack: service
`0000fff0-0000-1000-8000-00805f9b34fb`, write `…fff2…`, notify `…fff1…`,
advertised name prefix `YS` / `TL`. See the
[AUTOBABA doc](autobaba-led-backpack.md) for the full BLE protocol.

### Backend API

popled.cn hosts seen in the app: `a.popled.cn` (main), `auth.popled.cn`,
`wxbtapp.popled.cn:8443` (material), `app.popled.cn` (help/privacy pages).
None are needed for local control. Vendor backend credentials recovered from
the app are excluded per the project clean-room rules.

## Tools Used

- [x] APK decompilation (jadx) — com.yj.led 1.3.6.32
- [ ] Wi-Fi / HCI capture (not performed; see the AUTOBABA doc for hardware-verified wire framing)

## References

- [Google Play: LED space](https://play.google.com/store/apps/details?id=com.yj.led)
- [App Store: LED space](https://apps.apple.com/us/app/led-space/id1431362600)
- [AUTOBABA LED Backpack](autobaba-led-backpack.md) — shared LOY SPACE protocol, hardware-verified framing
- [NYAN BT Image Controller](nyan-bt-image-controller.md) — BLE-only sibling on the same platform

## Contributors

- APK static analysis (jadx decompilation)
