# LED Sign & Panel Design Apps

A survey of the phone apps used to *design* content for wearable and vehicle LED signs — the
panels on backpacks, hydration packs, hats, masks, shoes, bikes and car rear windows.

These products are a near-perfect fit for this project's thesis. The hardware is durable, cheap
and widely sold; the software is not. The apps are white-labelled OEM builds, typically rated
2.0–3.5, that break on OS updates, demand accounts to draw a bitmap, lose saved designs, and
disappear from the stores when the reseller moves on. A panel with no working app is landfill.

## Why the app matters more than the brand

Almost none of these signs are designed by the company whose name is on the bag. A handful of
Shenzhen OEMs build the controller boards and ship a companion app; resellers rebrand the
finished product. **The app is the real identity of the device.** Two backpacks from unrelated
brands with the same app share a protocol; the same brand across two production runs may not.

The Lunchbox / LEDs 2 RAVE 4 Dream Skin is the textbook case: three generations, three different
apps ([LED CHORD → SPOTLED → iLEDColor](leds2rave4-lunchbox-led.md)), with the third swap
happening *mid-production-run* on an otherwise identical-looking product.

So: identify the app first, then the protocol. When triaging an unknown sign, check the app
listed on the product page (or the app already installed on the owner's phone) before scanning.

## App inventory

### Documented here

| App | Android package | Device family | Transport | Protocol doc |
|-----|-----------------|---------------|-----------|--------------|
| SPOTLED | `com.led.spotled` | Matrix panels for packs, hats, badges, banner signs; Lunchbox Dream Skin 2.0/3.0 | BLE | [SPOTLED LED Panels](spotled-led-panel.md) |
| LED CHORD | `com.spled.pzse` | SP107E/SP110E SPI pixel controllers; Lunchbox Dream Skin v1 | BLE | [LEDs2Rave4 / Lunchbox](leds2rave4-lunchbox-led.md) |
| LOY SPACE | `com.yskd.loywf` | Full-color LED backpack screens (popled.cn platform) | BLE + Wi-Fi | [AUTOBABA LED Backpack](autobaba-led-backpack.md) |
| NYAN GEAR | `com.nyan.gear` | BLE-only white-label reskin of the LOY SPACE platform | BLE | [Nyan BT Image Controller](nyan-bt-image-controller.md) |
| CoolLED1248 | `com.jtkj.led1248` | Car/bike/badge/banner signs sold unbranded | BLE | [CoolLEDX / CoolLED1248](coolledx-led-sign.md) |
| iDotMatrix | `com.tech.idotmatrix` | Pixel display panels, 10×10 to 32×32 | BLE | [iDotMatrix](idotmatrix.md) |
| Magic Display | `com.tirohk.magicdisplay` | LED shoes, bags, hats (Quintic QPP, AES-128) | BLE | [Magic Display](magic-display.md) |
| Bluetooth LED Name Badge | `com.yannis.ledcard` | 11×44 mono badges (FOSSASIA "Badge Magic" hardware) | BLE | [Bluetooth LED Name Badge](bluetooth-led-name-badge.md) |
| Shining Mask | `cn.com.heaton.shiningmask` | LED face masks | BLE | [Shining Mask](shining-mask.md) |
| Shining Glasses | `com.icwork.shiningglass` | LED glasses | BLE | [Shining Glasses](shining-glasses.md) |

### Tracked, protocol not yet mapped

| App | Android package | Device family | Transport | Target starter |
|-----|-----------------|---------------|-----------|----------------|
| iLEDColor | `com.led.iledcolor` | Matrix panels; **current** Lunchbox DreamPanel v3 boards | BLE | [`targets/iledcolor-led-panel.md`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/targets/iledcolor-led-panel.md) |
| LED space | `com.yj.led` | YSP-001 Wi-Fi backpack screens, LED vests, LED clothing | Wi-Fi (AP) | [`targets/led-space.md`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/targets/led-space.md) |
| Divoom | `com.divoom.Divoom` | Pixoo-16/32/64, Timebox, Ditoo pixel displays | Wi-Fi HTTP + BLE | [`targets/divoom-pixoo.md`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/blob/main/targets/divoom-pixoo.md) |

## Platform clusters

Apps cluster into a small number of OEM platforms. Recognising the cluster short-circuits most of
the reverse-engineering work.

### popled.cn / LOY SPACE cluster

LOY SPACE (`com.yskd.loywf`), NYAN GEAR (`com.nyan.gear`) and very likely LED space
(`com.yj.led`) are all built on the popled.cn backend. Signals: BLE name prefix `YS` or `TL`,
Wi-Fi SSID containing `YS` with default password `12345678`, UDP discovery on port 9090 to
`192.168.4.255`, and an `aa 55` framed TLV packet carrying JSON commands. The LED space product
literature names the panel `YSP-001`, which is the same naming family. Confirming the LED space
link would fold an entire second app into an already-documented protocol.

### SPOTLED / iLEDColor cluster

Both are matrix-panel design apps in the same product niche, and both have shipped on Lunchbox
DreamPanel hardware. [SPOTLED is fully mapped](spotled-led-panel.md) and spans products from
dozens of unrelated resellers — hats, badges, chest panels, banner signs — so the `0xFF20` service
is worth probing on any unknown wearable matrix panel. Whether iLEDColor shares that wire protocol
is unknown and worth a direct test: a DreamPanel v3 that pairs with iLEDColor should be probed for
`0xFF20` before assuming a new protocol.

### Quintic QPP cluster

Magic Display, Shining Mask and Shining Glasses all sit on Quintic (NXP QN-series) silicon using
the Quintic Private Profile: service `0xFEE9`, OTA on `0xFEE8`, AES-128 payload encryption via a
bundled `libAES.so`. Same UUIDs, different command sets. A new LED wearable advertising `0xFEE9`
with an `libAES.so` in its APK belongs here.

### CoolLED generations

`CoolLED*` is one advertising name across at least seven hardware generations with two protocol
families. The advertisement itself carries panel width, height and color mode, so a client can
adapt without user configuration — but the generation determines the command table. See the
[CoolLEDX doc](coolledx-led-sign.md).

## Triage checklist for an unknown LED sign

1. **Identify the app.** Product page screenshot, printed insert, or what's on the owner's phone.
   Record the exact package ID — display names are reused freely across unrelated apps.
2. **Scan before connecting.** `./scripts/detect_devices.sh` — capture the advertised local name,
   service UUIDs *and the raw manufacturer data*. Several of these families encode panel geometry
   and color depth in the advertisement.
3. **Match against the clusters above** before doing any new work.
4. **Prefer asking the device over guessing.** SPOTLED has `GetDisplayInfo`; CoolLEDX puts
   geometry in the advertisement; the popled.cn platform has `{get:"dev_info"}`. Hardcoding a
   resolution from a marketing spec is how a replacement app breaks on the next batch.
5. **Static-analyse the APK** (`./scripts/run_static_target.sh <target>`) for UUIDs, chunk sizes
   and CRC routines. A build with no UUIDs in the decompiled output usually means dynamic setup
   or a cloud-mediated path — escalate straight to a live capture.
6. **Capture connect + upload one small GIF.** That single flow exercises handshake, geometry
   negotiation, chunking and flow control, which is most of what a replacement app needs.

## Common patterns across the category

- **Design happens on the phone.** The panel receives bitmaps or frame sequences, not vector or
  text primitives. A replacement app is a renderer plus a chunked uploader.
- **Flow control is device-driven.** Every mapped protocol in this category has a
  continue/ack response that gates the next chunk. Ignoring it produces truncated uploads that
  look like corruption.
- **MTU is a common failure mode.** SPOTLED explicitly reports a pause-sending error for chunks
  that are too large *or too small*.
- **No pairing, no auth.** Most of these connect without bonding and accept commands from anyone
  in range. Treat as a privacy consideration for the wearer, not as a protocol obstacle.
- **Accounts are bolted on.** Cloud login typically gates only the content library, not device
  control — which is why local-first replacements are viable for nearly all of them.

## References

- [`python-spotled`](https://github.com/iwalton3/python-spotled) — SPOTLED BLE protocol
- [`coolledx-driver`](https://github.com/UpDryTwist/coolledx-driver) — CoolLEDX BLE protocol
- [FOSSASIA Badge Magic firmware](https://github.com/fossasia/badgemagic-firmware) — open firmware for the 11×44 badges
- [Reverse engineering a Bluetooth LED name badge](http://nilhcem.com/iot/reverse-engineering-bluetooth-led-name-badge) — Nilhcem
- [`offe/mi-led-display`](https://github.com/offe/mi-led-display) — Merkury Innovations Multicolor Matrix BLE protocol
- [`4ch1m/pixoo-rest`](https://github.com/4ch1m/pixoo-rest) — Divoom Pixoo local HTTP API
- [`SomethingWithComputers/pixoo`](https://github.com/SomethingWithComputers/pixoo) — Divoom Pixoo Python library
