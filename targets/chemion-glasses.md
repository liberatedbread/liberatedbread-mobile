# CHEMION LED glasses / CHEMION HAT — target spec starter

## Target metadata
- target_id: chemion-glasses
- app package_id(s): com.neofect.chemion (Android, analyzed v3.0.5 / versionCode 172;
  Flutter app — all logic in the Dart AOT snapshot, no native protocol code)
- device class: programmable LED matrix wearables — glasses (CHEMION Original) and
  LED cap (CHEMION HAT). Hardware is CoolLED OEM; some units advertise "CoolLED" names.
- transport(s): Bluetooth (BLE) only — no Wi-Fi/UDP/SSDP/mDNS code anywhere in the app
- local-only viability: **high**. The whole control surface is one BLE frame protocol
  (framing + checksum + message map recovered); the vendor cloud is only a content
  store (font/sound packs as ZIP) plus login/SNS, none of which control needs.

## Known facts (from static RE of app v3.0.5)
- Two device types sharing one frame protocol:
  - **CHEMION Original (glasses)**: Nordic UART service
    `6e400001-b5a3-f393-e0a9-e50e24dcca9e`, write `6e400002-…`, notify `6e400003-…`.
    Matrix 9×24 @ 2 bpp (54-byte frames); ~6 save slots. nRF51 chip (2015 wiki).
  - **CHEMION HAT**: service `4b0d67ea-2faf-4b3c-8c53-f6af0f0171f5`, write
    `4b0d67eb-…`, notify `4b0d67ec-…`. Matrix 12×32 @ 4 bpp color (1536-byte
    frames); ~144 slots.
- Frame: `[0xFA][cmd][lenHi][lenLo][payload][XOR of payload][0x55][0xA9]`,
  one frame per write, no app-level chunking (long writes permitted).
  cmd = command type: request 0x01 / reply 0x02 / stream 0x03 / notify 0x04 /
  error 0x05 / identify 0x06.
- **Checksum solved**: plain XOR over the payload bytes only. This was the open
  question left by the 2015 public RE (github.com/gsuberland/ChemionHacking).
- Message IDs (2-byte big-endian inside the payload): power off 2, battery 3,
  heartbeat 5 (sent every 5 s by the app), realtime stream 6, slot/status 7,
  sound-stream marker 9, frame data 10, transfer start/end 11/12, play 13,
  slot ops 14/16, slot-frame upload start/end 20/21. Three msgIds load from
  unresolved static fields (likely 1, 8, 15/17).
- Full per-msgId payload skeletons are in `device-specs/devices/chemion-glasses.yaml`
  (the spec is canonical; this file is the research wrapper).
- No BLE-link encryption (the AES/CRC32 code in the app is a stock ZIP decoder
  for content packs). No DFU/OTA path in v3.0.5 — the 2015 app generation had
  nRF legacy DFU with four Intel-HEX images (per the public wiki).

## Device discovery signals
- BLE advertised name prefixes: `CHEMION`, `HAT`; display-name logic also matches
  names containing `CoolLED` (OEM branding).
- Service UUIDs:
  - `6e400001-b5a3-f393-e0a9-e50e24dcca9e` — glasses (Nordic UART)
  - `4b0d67ea-2faf-4b3c-8c53-f6af0f0171f5` — HAT
- Content-store domains (not needed for control): api.chemi-on.com,
  dev.api.chemi-on.com, content.chemi-on.com (`/data/` ZIP packs),
  www.chemionglasses.com.

## Threat model + guardrails
- Owned devices only. The devices connect without bonding and accept writes from
  anyone in range — including power-off. Treat that as a wearer-privacy/annoyance
  consideration to document for users, not a surface to tool against.
- The battery-reply and error-frame layouts are unverified; do not publish decoded
  fields until a capture confirms them.

## Remaining experiments
1) **RX capture** (highest value): HCI snoop of connect → battery query →
   heartbeat → power off. Confirms the notify-channel framing, battery reply
   layout and error frames, all currently MEDIUM.
2) **Slot upload capture**: one full design upload — establishes which of
   11/12 vs 20/21 opens/closes the transfer, where the slot index and frame
   count actually ride, and any timing data in msgId 13's optional trailer.
3) **Pixel encoding**: verify 2 bpp orientation/bit order on the glasses and
   the HAT's 4 bpp nibble order/palette by pushing one known pattern.
4) **Characteristic roles on air**: write/notify roles are assigned by NUS
   convention; confirm on both device types (HAT especially).
5) **MTU behavior for HAT frames**: a full HAT frame message is ~1546 bytes;
   capture whether the phone negotiates a large MTU + long write or chunks.
6) **Heartbeat requirement**: is the 5 s heartbeat mandatory to hold the link,
   or optional? Test by omitting it.
7) Resolve the three static msgId keys (likely 1/8/15-or-17) by exercising the
   app's less-used UI paths (status, delete, any DFU remnant).
8) Check whether CoolLED-branded units speak the byte-identical protocol.

## Control surface inventory (replacement app MVP)
- scan (name prefixes + both service UUIDs), connect, enable notifications
- 5 s heartbeat loop; battery query with reply decode (after experiment 1)
- realtime frame streaming: render 9×24 @ 2 bpp (glasses) / 12×32 @ 4 bpp (HAT)
- slot upload (start → frame blocks → end), play slot, delete/free slot
- power off
- local design storage that survives app reinstall (the vendor app keeps designs
  behind its content store/account)

## References
- Public prior RE (2015-era app v1.x; checksum question answered by our work):
  https://github.com/gsuberland/ChemionHacking
- CHEMION app on Google Play: https://play.google.com/store/apps/details?id=com.neofect.chemion
- Vendor site: https://www.chemionglasses.com/
- Machine-readable spec (canonical): `device-specs/devices/chemion-glasses.yaml`
