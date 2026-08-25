# LotusLamp X (Shenzhen ELK) — target spec starter

## Target metadata
- target_id: lotuslamp-x
- app package_id(s): com.szelk.ledlamppro (LotusLamp X), analyzed v5.19.08
  (versionCode 411, minSdk 26)
- vendor: Shenzhen ELK; app help center and rebranded privacy pages live on
  elkble.com / elkled.com / opt-7.com
- device class: BLE addressable RGB LED strip/lamp controllers (ELK-/MELK-/ELBU-
  name families plus many OEM rebrands)
- transport(s): Bluetooth (BLE) only — GATT connection, plus two connectionless
  advertising paths (broadcast control and mesh). No Wi-Fi/UDP anywhere in the
  app.
- local-only viability: high for the E1 GATT family — independently
  reimplemented and live-tested (see References). Mesh provisioning and the
  encrypted-firmware variant are partially mapped.

## One app, three control paths
The same app drives every device in the family, selecting a frame format per
device type:

| Path | Framing | Carrier |
|---|---|---|
| GATT (primary) | 9-byte E1: `7E <len> <cmd> <params> EF` | write `0xFFF3`, notify `0xFFF4` on service `0xFFF0` |
| GATT (other families) | E2: `8E <len+1> <cmd> …` (no trailer); E3: `2E <cmd> … 2F` (16/128 bytes) | same characteristics |
| Broadcast (connectionless) | E1/E2 command inside phone-originated advertisement | company ID `0xE190` (E1) / `0xE290` (E2) |
| Mesh (connectionless) | 22-byte packet, CRC24-core truncated to CRC16 | company ID `0xBE99` |

A niche third family uses `55 A5 05 03 R G B FF FF FF`-style frames — ignore
unless met in the field.

## Known facts (static + public corroboration)
- Service `0000fff0-…`, write `0000fff3-…` (write-without-response), notify
  `0000fff4-…`. Standard DIS characteristics and Battery Level are read on
  connect.
- The 9-byte E1 frame and these UUIDs match the published RE
  (wporter82/lotus-lamp-python) exactly; that library is live-tested on a
  MELK-OA10 and publishes the full 213-mode animation table (modes 0-212).
- The `<len>` byte (byte 1) appears len-tolerant on real firmware: the app
  emits 4 for BRIGHTNESS while the independent implementation used 7 with
  success. Emit app-canonical values, don't treat a mismatch as fatal.
- Core E1 commands: BRIGHTNESS 0x01, SPEED 0x02, MODE 0x03, ON_OFF 0x04,
  COLOR 0x05, TIMER_SWITCH 0x82, DATA_TIME 0x83, INFO 0x84; a ~70-opcode map
  covering scenes, DIY images, rhythm, mesh groups and OTA is in the device
  spec notes.
- Devices whose advertised name carries `*` as the 4th character (`ELK*…`)
  run firmware that obfuscates the E1 frame for ON_OFF/MODE/BRIGHTNESS with a
  random-seeded XOR keystream plus an app-embedded repeating preset key. It is
  toy obfuscation, not AES; the key is recoverable from the app (bytes not
  reproduced, per clean-room rules).
- Mesh advertisements read by the app's scanner: company ID `0xBE99`, and when
  `data[1]==0x40`, `data[2]` is a device-type ID used to synthesize a display
  name.
- OTA, if offered, rides the GATT channel (READY_UPDATE 0x43 + image opcodes
  0x52-0x54 in 500-byte packets). No DFU service, no firmware file URLs in the
  app.

## Device discovery signals
- BLE advertised name prefixes: `ELK-`, `MELK-`, `ELBU-`, plus OEM variants
  `HX6-`, `HCW-`, `BYC-`, `SHY-`, `MHRS-`, `THUNDEROBOT`, and names containing
  `LED LIGHT STRIP` or `LED Constellation Lights`. Encrypted firmware:
  `ELK*` (`*` as 4th character). The vendor app's scanner *drops* names
  starting with `ELKP`.
- Service UUID `0000fff0-0000-1000-8000-00805f9b34fb` in the advertisement.
- Manufacturer data company IDs: `0xBE99` (device-side mesh/broadcast adverts),
  `0xE190` / `0xE290` (phone-side command adverts — seeing these means an ELK
  controller app is nearby, not a lamp).

## Threat model + guardrails
- Owned devices only. Classic firmware has no pairing, bonding or auth — any
  central in range can connect and write, and the lamp holds a single BLE link
  (a nuisance, not a hardening boundary). Note as an owner-privacy fact.
- The `ELK*` obfuscation is not access control: the preset key ships in the
  app. Do not present it as security in any consumer UI.
- Privacy: the vendor app uploads device stats/telemetry to
  `lotus.elkled.com:8082` and self-updates from `elkble.com`. The lamp itself
  never needs the network; a replacement client keeps the device fully local.

## Remaining experiments
1) **FFF4 notification semantics** — highest value. HCI snoop connect → power
   toggle → color/mode change and decode the status echoes (7E..EF framed,
   includes the INFO/0x84 reply). Unlocks real state readback.
2) **Encrypted (`ELK*`) variant** — confirm which opcodes beyond
   ON_OFF/MODE/BRIGHTNESS take the obfuscated frame on current firmware, and
   validate the keystream/preset-key scheme against a live unit.
3) **Mesh provisioning** — trace familyId/roomId/groupId assignment
   (0xBE99 path) end to end; only partially traced statically.
4) **Broadcast control** — verify the `0xE190`/`0xE290` advertisement payload
   (seq + `13 01 BE` + E1 frame + sum16 LE) against a listening lamp.
5) Confirm the `<len>`-byte tolerance across a second model (only MELK-OA10 is
   live-tested) and check whether SET_RESTORE_FACTORY (0x87) does what the
   name says.

## Control surface inventory (replacement app MVP)
- scan + connect (service `0xFFF0`; honor the single-link constraint), no
  pairing flow
- power on/off, static RGB color, brightness 0-100, speed 0-100
- animation mode 0-212 with the published 213-name table
- clock sync (0x83) and on/off timers (0x82)
- stretch: mic/rhythm modes, scene/DIY image upload, mesh groups, OTA

## References
- lotus-lamp on PyPI (independent RE, live-tested on MELK-OA10):
  https://pypi.org/project/lotus-lamp/
- wporter82/lotus-lamp-python (protocol doc in docs/PROTOCOL.md):
  https://github.com/wporter82/lotus-lamp-python
- LotusLamp X on Google Play:
  https://play.google.com/store/apps/details?id=com.szelk.ledlamppro
- Vendor app-update/help infrastructure: https://www.elkble.com ,
  https://faq.elkled.com
- Sibling specs in this repo: `device-specs/devices/elk-bledom-led-strip.yaml`
  and `device-specs/devices/wl-smartled-pixel-strips.yaml` (same 7E..EF E1
  frame family — keep in sync)
