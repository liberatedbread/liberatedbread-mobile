# iLEDColor LED panel — implementation target

## Target metadata

- target_id: iledcolor-led-panel
- app package_id(s): com.led.iledcolor (iLEDColor)
- iOS app id: 6737223690
- publisher: Shenzhen I-ledshow Technology Co., Ltd.
- device class: programmable full-color LED matrix panel
- transport(s): BLE, confirmed
- local-only viability: **confirmed for Connect, TestPass and content upload**

## Current status

This is the app for recent Lunchbox / LEDs 2 RAVE 4 DreamPanel v3 boards. The vendor's
published `led_bt_jl_ota` plugin supplied the protocol, and an independent Rust client
corroborated it. On 2026-11-07 a live unit confirmed GATT, advertisement geometry,
Connect/TestPass, a static RGB upload and an eight-frame GIF-container upload. A
corrected vendor-native three-frame raw-RGB animation completed 38 chunks and stayed
active on 2026-11-08, proving the animation path rather than just its ACKs.

The authoritative output is `device-specs/devices/iledcolor-led-panel.yaml`, with the
owner guide at `docs/devices/iledcolor-led-panel.md`.

## Confirmed signals and protocol

- Advertised name prefix: `iledcolor-`; tested unit also advertised AF30.
- Manufacturer data carries big-endian width/height; tested field order is 32×64, with
  no physical-orientation assumption.
- Control service: A950, with A951 command and A952 bulk data (both
  write-without-response) and A953 notify.
- OTA service: AE00 / AE01 write-without-response / AE02 notify, enumerated but unused.
- No SPOTLED FF20 service was present. AF30 was not present in fresh GATT discovery and
  is not a substitute command service.
- A951 framing: `54`, handle, big-endian length, payload, big-endian additive checksum.
- Connect: `54 0d 00 03 00 00 64`; reply `54 0d 00 04 00 00 00 65`.
- Default TestPass returned status 3 (no password configured).
- Static uploads completed with 492-byte chunks at MTU 517. The eight-frame
  GIF-container upload was acknowledged but restored the old program, so the working
  animation evidence is instead the corrected vendor-native three-frame raw-RGB stream
  (item type 2 plus per-frame durations), which completed 38 chunks and stayed active.

## Remaining experiments

1. Reversible brightness and LedEnable writes; playlist and password behavior on a
   password-enabled unit.
2. Official-app HCI capture to compare MTU and richer program/resource behavior.
3. Maximum resource size, other geometries and old-protocol framing.
4. Factory reset, power-cycle persistence, OTA entry and recovery.

## Replacement app MVP

- Scan by name/manufacturer data, connect and query advertised geometry.
- Connect/TestPass without an account; ask the owner when a password is configured.
- Upload still images and animations with device-driven ACK handling.
- Store designs locally; do not touch OTA without an image and recovery path.

## References

- https://pub.dev/packages/led_bt_jl_ota
- https://github.com/akkaisinabin/iledcolor-rs
- https://github.com/Jieli-Tech/Android-JL_OTA
- https://apps.apple.com/us/app/iledcolor/id6737223690
- https://play.google.com/store/apps/details?id=com.led.iledcolor
- https://leds2rave4.com/blogs/animated-gifs/new-batch-of-v3-s-now-use-iledcolor-app
