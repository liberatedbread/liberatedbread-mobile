# SP105E "Magic LED" pixel controller — target spec starter

## Target metadata
- target_id: sp105e-magic-led
- app package_id(s): com.vengean.magicled (Magic-LED v2.2.1, versionCode 16, targetSdk 36)
- device class: Bluetooth SPI pixel ("dream color") LED strip controller
- transport(s): Bluetooth (BLE GATT only — no sockets, HTTP(S), OTA or analytics anywhere
  in the app binary)
- local-only viability: **high** — the app is fully local (no account, no cloud), the
  complete command set is recovered, and the only access control is an obfuscation-grade
  handshake whose formula is fully documented in the device spec

## Known facts (static decompile, Magic-LED v2.2.1)
- BLE serial-port profile: service `0xFFE0`, single characteristic `0xFFE1` (write +
  notify), notifications via the standard CCCD `0x2902`. No DFU service, no chip-vendor
  SDK fingerprints (not JieLi/Telink/Beken/Nordic), no native libraries.
- All commands are 5-byte frames `[0x38, p0, p1, p2, opcode]`, no checksum. Unused
  parameter slots carry random filler nudged to avoid emitting `0x38` or `0x83`.
- Full opcode map recovered: power toggle, handshake, status query, auto cycle, relative
  speed/brightness steps, five static colors, custom solid RGB, jump-to-mode 1..200,
  pixel count (u16 BE), RGB order (6 entries), IC type (27-entry table from SM16703
  through SK9822). Four opcodes are defined but never sent by this app version
  (mode up/down, led_match, clear).
- Handshake: `check_device` (0xD5) with three random bytes; device must reply
  `00 01 02 03 04 05 06 KEY` with `KEY = ((r2>>5)&7) | ((r0<<1)&0x53) | r1` before the
  app will talk further. Obfuscation-grade, not crypto — the formula is in the spec.
- Status: `get_info` (0x10) returns an 8-byte block (power, mode, speed, brightness,
  IC index, RGB-order index, u16 BE pixel count). Any 8-byte notification is parsed as
  status.
- Speed and brightness have no absolute setter — relative steps only, current values
  come back in the status reply.
- The app's only cryptography is a signature self-check on its own APK; none of it
  touches the device protocol.

## Device discovery signals
- BLE advertised local name: exactly **`SP105E`** — the vendor app's device list keeps
  only exact-name matches (no prefix matching, no scan filter), so exact match is the
  reliable discriminator.
- Service UUID: `0000ffe0-0000-1000-8000-00805f9b34fb`.
- Same `0xFFE0` service as the SP107E/SP110E siblings
  (`device-specs/devices/leds2rave4-lunchbox-led.yaml`) — those advertise as
  `SP107e`/`SP110E` and speak a different 4-byte opcode set, so name match (or a failed
  SP105E handshake) is how a multi-family scanner tells them apart.

## Threat model + guardrails
- Owned devices only. The controller accepts a connection from any central in range and
  the handshake key is public knowledge (it is in our spec), so anyone nearby can change
  the strip — worth noting for wearable/vehicle installations, not an attack surface to
  tool against.
- `led_match` (0x1D) and `clear` (0x0F) are defined but never sent by the app; their
  effects are unverified. Do not probe them on hardware you cannot reconfigure.

## Remaining experiments
1) **Live HCI capture of a connect + full pass** — highest value. Confirm the handshake
   reply bytes on the wire, the 8-byte status layout, and whether device→app frames carry
   an `0x83` header (inferred from the app's filler-avoidance rule, unverified).
2) Probe speed/brightness accepted ranges by stepping to the floor/ceiling and reading
   status back (clones commonly use 1..31 / 1..255).
3) Determine whether `set_ic_type` / `set_rgb_order` / `set_pixels` persist across power
   cycles.
4) Capture the effect of the four never-sent opcodes (mode_up 0x17, mode_down 0x05,
   led_match 0x1D, clear 0x0F) — `clear` is the probable factory reset.
5) Record what the status `mode` byte reports while a static-color or auto mode is
   active.

## Control surface inventory (replacement app MVP)
- scan (exact name `SP105E`) → connect → enable notifications → `check_device`
  handshake → `get_info`
- power toggle with state read-back from status byte 0
- effect selection: numeric 1..200 jump, auto cycle, five static presets, custom solid
  RGB
- relative speed/brightness controls driven off the status values (get_info → step)
- strip configuration: IC type (27-entry table), RGB order, pixel count
- command pacing ~200 ms; retry failed writes once

## References
- BTF-LIGHTING SP105E product page: https://www.btf-lighting.com/products/sp105e-spi-led-controller
- Super Bright LEDs SP105E (Magic-LED) page: https://www.superbrightleds.com/magic-led-bluetooth-controller-for-digital-rgb-led-strip-lights-sp105e
- Magic-LED on Google Play: https://play.google.com/store/apps/details?id=com.vengean.magicled
- Sibling family spec (SP107E/SP110E, same 0xFFE0 service):
  `device-specs/devices/leds2rave4-lunchbox-led.yaml`, dossier `targets/leds2rave4-lunchbox-led.md`
- SP110E protocol gist (sibling, BLE-sniffed): https://gist.github.com/mbullington/37957501a07ad065b67d4e8d39bfe012
