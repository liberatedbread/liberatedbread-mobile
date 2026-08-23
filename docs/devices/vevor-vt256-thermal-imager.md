# Vevor VT256 Thermal Imager (Hti-Xintai HT-W01)

> **Status**: Research (protocol recovered from app decompile; untested against hardware)
> **Protocol**: WiFi (device-hosted AP; RTSP + raw TCP + UDP)
> **Manufacturer**: Vevor (brand); OEM Dongguan Xintai Instrument Co., Ltd. (Hti-Xintai / HTI)
> **Manufacturer Status**: Active (protocol closed; no cloud dependency)

## Overview

The Vevor VT256 is a 256x192 phone thermal imager sold for Android/iOS. It is a
rebadge of the Hti-Xintai HT-W01: Vevor's own product page QR decodes to Hti's
app-download page, Vevor's FAQ names the "W01" app and the Wi-Fi connection
model, and the Vevor manual (covering YXP160/YXP256/VT256) is titled "VEVOR
HT-W01". It is NOT the Infiray/Xinfrared P2 Pro that shares its headline specs —
the P2 Pro is USB/UVC with mature FOSS drivers; this one is a Wi-Fi device with
its own simple protocol, documented here for the first time.

The camera is permanently its own Wi-Fi access point; the phone joins it. All
three channels (video, command, raw thermal data) are unauthenticated and fully
local — there is no cloud in the picture at all.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Vevor VT256 (manual family: YXP160, YXP256); OEM: Hti-Xintai HT-W01 |
| Detector | VOx uncooled microbolometer, 256x192 @ 12 um, 8-14 um, <=25 Hz, NETD <=50 mK |
| Visible camera | 640x480, PIP/fusion rendered on-device |
| Temperature range | -20..550 C (Small range -20..120, Large range 120..550) |
| Radio | Wi-Fi AP in the camera (2.4 GHz; channel configurable 1-8 or auto) |
| FCC ID | Not recovered |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No provisioning — the camera IS the access point |
| Method | `none` (client joins the device's AP) |
| Setup AP / advertised name | `HT-W01-*` |
| Passphrase protection | not_applicable (AP passphrase is the fixed constant `12345678`) |
| Confidence | medium (manual + FAQ, not replayed) |

Power the camera, join `HT-W01-*` with passphrase `12345678`, reach it at
`192.168.1.10`. Note the phone loses internet access while joined to the
camera — that is expected, not a failure.

**Factory reset**: not fully established. The command protocol carries a
`ResetConfig` action (0x00, resets stored configuration) and a `RestartDevice`
action (0x02, reboots). Whether `ResetConfig` also restores the AP
SSID/passphrase, and whether a hardware-button reset exists, is unknown.
Confidence: low.

**Rebinding to a new network**: not applicable — the camera never joins a home
network. A new phone just joins the same `HT-W01-*` AP.

## Protocol Summary

All channels terminate at the camera's fixed address `192.168.1.10`:

| Channel | Transport | Endpoint |
|---------|-----------|----------|
| Video (visible+thermal composite, H.264) | RTSP | `rtsp://192.168.1.10:654/test.264` |
| Command/config | TCP | `192.168.1.10:8080` |
| Raw thermal + temperature frames | UDP | `192.168.1.10:8888` (client binds local 8090) |

The RTSP stream is plain and unauthenticated — VLC or FFmpeg open it as-is.

### Command frame (TCP 8080)

Fixed layout, 25 bytes of overhead plus the data unit:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Magic `0xFB` |
| 1 | 4 | Length, little-endian u32 = total frame size − 3 |
| 5 | 1 | Command type (see below) |
| 6 | 17 | Reserved (app sends zeros) |
| 23 | N | Data unit |
| 23+N | 2 | CRC-16 (poly 0x1021, init 0x0000, no reflection, no final XOR) over bytes 1..(size−3), appended **low byte first** |

Command types: `0x31` heartbeat (data unit: 1-byte incrementing counter),
`0x33` GET_PARAM (`[paramId]`), `0x34` SET_PARAM (`[paramId, value...]`),
`0x35` ACTION (`[actionId, value...]`). Status codes in replies: `0x00`
SUCCESS, `0x1F` POST_CMS, `0x33` ERROR_PARAM, `0x44` ERROR_CRC, `0xFD`
UNKNOWN_CMD.

Parameter ids: `1` palette, `3` measuring range (0=Large 120..550 C, 1=Small
−20..120 C), `4` emissivity (value = emissivity×100), `6` reflect-temp
(deprecated), `8` distance (2-byte LE, unit unverified), `9` brightness,
`10` contrast, `11` TNR (deprecated), `12` SNR, `13` DE, `15` boot-5-minutes,
`16` version info, `17` Wi-Fi channel (0=auto, 1-8).

Palette values: 1 white-hot, 3 sepia, 4 ironbow, 5 rainbow, 6 night, 7 aurora,
8 red-hot, 9 jungle, 10 medical, 11 black-hot.

Action ids: `0x00` ResetConfig, `0x01` RefreshShutter (FFC), `0x02`
RestartDevice, `0x0A`–`0x11` factory-mode calibration points (do not send).

#### Command: Set palette to white-hot (worked example)

**Request** (complete wire frame; every command frame in the spec YAML is
byte-exact in this form):

```
fb 18 00 00 00 34 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 01 43 a0
```

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | `fb` magic |
| 1 | 4 | `18 00 00 00` = length 24 = 27 − 3 |
| 5 | 1 | `34` SET_PARAM |
| 6 | 17 | zeros |
| 23 | 1 | `01` param id: palette |
| 24 | 1 | `01` value: white-hot |
| 25 | 2 | `43 a0` CRC-16, low byte first |

### Thermal data stream (UDP 8888)

Frames are delimited by 2-byte marker pairs: thermal image frames open with
`FB FC` and close with `FC FB`; temperature frames open with `FB FE` and close
with `FE FB`. The thermal matrix is 256x192. Per-pixel element width,
temperature scaling and datagram packing are NOT recovered — first capture
should dump frames between the markers.

## Tools Used

- [x] jadx (decompile of `com.htimeter.w01` v1.1.4, sha256
      `219010668b155e5bd125cd7e0c17376ecc8b58d21256b3669c38adfb7183e477`,
      from Hti's official download page)
- [x] Python scratch re-implementation of the frame encoder (generated the
      byte-exact example frames; not yet replayed against hardware)
- [ ] Wireshark / packet capture — the needed next step to promote all
      `reported` facts to `confirmed` and to recover the UDP pixel format

## References

- [Hti HT-W01 product page (OEM)](https://hti-instrument.com/products/ht-w01-wifi-thermal-imaging-camera-256-192)
- [Hti app download page — official APK source](https://htimeter.m.icoc.me/h-col-103.html)
- [Vevor support FAQ (rebadge evidence)](https://www.vevor.com/goods/faq/inquiry?goodSn=KDSRCXY2561956M8NV0)
- [VEVOR HT-W01 manual (YXP160/YXP256/VT256)](https://manuals.plus/asin/B0FV77VZP9)
- [LeoDJ/P2Pro-Viewer — the OTHER 256x192 imager family (not this device)](https://github.com/LeoDJ/P2Pro-Viewer)

## Contributors

- Liberated Bread research agent — initial research and protocol recovery (2026-08-19)
