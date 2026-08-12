# iLEDColor LED panel — target spec starter

## Target metadata
- target_id: iledcolor-led-panel
- app package_id(s): com.led.iledcolor (iLEDColor)
- iOS app id: 6737223690
- publisher: Shenzhen I-ledshow Technology Co., Ltd.
- device class: programmable full-color LED matrix panel (backpack / pack skin / wearable)
- transport(s): Bluetooth (BLE expected)
- local-only viability: unknown — app forces account registration, but device control is
  probably local. Needs confirmation.

## Why this target matters
This is the app currently shipping on new Lunchbox / LEDs 2 RAVE 4 **DreamPanel v3** hardware.
LEDs 2 RAVE 4 switched the controller board partway through the v3 production run and moved from
SPOTLED to iLEDColor. Every panel sold from that point forward depends on an app rated ~2.2 with
recurring reports of registration failures, post-update crashes and lost saved programs.

It is also the one LED panel target in this repo where a static pass produced **nothing**: the
existing `leds2rave4-lunchbox-led` spec records that the iLEDColor APK "exposed NO BLE UUIDs
statically (likely cloud-only)". That makes live capture the only path forward.

## Known facts (public)
- App features: patterns, text, graffiti/freehand drawing, GIF import, music rhythm, microphone
  rhythm, searchable online material library.
- Distributed on both Google Play and the App Store; not region-locked.
- Version history shows GIF import optimisation (v1.0.28), material search (v1.0.34) and text
  rotation (v1.0.37) — consistent with a bitmap-render-and-upload design tool.
- LEDs 2 RAVE 4 guidance: power the panel on and read the serial number — if it renders
  **horizontally**, the unit is a new-board revision and needs iLEDColor rather than SPOTLED.

## Device discovery signals (hypotheses)
- BLE advertised name: unknown. Older Lunchbox panels used the `LBXDRMSKIN_LED_` prefix; the new
  board may or may not keep it.
- Service UUIDs: unknown. **Probe for `0000ff20-0000-1000-8000-00805f9b34fb` first** — if the new
  board still speaks SPOTLED framing, this target collapses into the existing spec.
- Manufacturer data: capture raw. Sibling families (CoolLEDX) encode panel geometry in the
  advertisement; worth checking before assuming a query command is needed.

## First experiments
1) Run ./scripts/detect_devices.sh next to a powered DreamPanel v3 (horizontal serial number).
   Save the full advertisement including manufacturer data.
2) Probe GATT for `0xFF20`/`0xFF21`/`0xFF22` (SPOTLED) and `0xFFF0`/`0xFFF1` (CoolLED-style)
   before anything else — a match saves the whole effort.
3) HCI snoop the minimum useful flow: connect → set brightness → upload one small GIF.
   That single capture covers handshake, geometry negotiation, chunking and flow control.
4) Determine whether device control works with the app logged **out**. If it does, the account is
   only gating the content library and a local-first replacement is straightforward.
5) Re-run static analysis on a current APK version with a UUID-string grep across native libs, not
   just the Java sources — an empty static result often means the UUID lives in a `.so`.

## Protocol hypotheses (to validate)
- Frame-based bitmap upload with a device-driven continue/ack, matching every other mapped panel
  in this category.
- Geometry either advertised or queryable; do not hardcode a resolution.
- The 2048-LED DreamPanel v3 claim suggests 64×32, unconfirmed.

## Replacement app MVP
- scan + connect without an account
- report panel geometry from the device, not from config
- set brightness
- upload a still image and an animated GIF, rendered client-side to the panel geometry
- store designs locally so they survive an app reinstall

## References
- https://apps.apple.com/us/app/iledcolor/id6737223690
- https://play.google.com/store/apps/details?id=com.led.iledcolor
- https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app
- https://leds2rave4.com/products/dreamskin-v3-the-dreampanel
