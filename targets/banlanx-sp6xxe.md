# BanlanX / Sperll SP6xxE pixel & PWM LED controllers — target spec starter

## Target metadata
- target_id: banlanx-sp6xxe
- app package_id: com.spled.scenex ("SceneX"), version 3.3.2 (versionCode 137),
  minSdk 24, targetSdk 36 — Flutter app; all protocol logic is Dart AOT-compiled
  into the native snapshot, the Java layer is only the Flutter shell
- device class: addressable (SPI pixel) and analog (PWM) LED strip controllers,
  single- and multi-channel, with music-reactive modes
- transport(s): Bluetooth (BLE); SoftAP Wi-Fi provisioning on dual-mode models;
  vendor cloud (app.ledhue.com) for remote/Alexa control and OTA checks
- local-only viability: high for the BLE command path — the plaintext framing is
  fully mapped by the open-source UniLED integration and needs no cloud; the new
  authenticated "ELS" channel on recent firmware is not yet mapped

## Product family
One app drives a whole controller family, and the framing differs by generation.
Identify the model before assuming a frame format.

| Models | Role | Framing (write char 0xFFE1) |
|---|---|---|
| SP601E | 2× SPI RGB, music | `[0xAA, opcode, len, payload…]` |
| SP602E / SP608E | 4×/8× SPI RGB, music | `[0x88, opcode, len, payload…]` |
| SP611E / SP617E / SP620E / SP621E | SPI/PWM ("BanlanX v2") | `[0xA0, opcode, len, payload…]` |
| SP613E / SP614E / SP623E / SP624E | SPI/PWM ("BanlanX v3") | `[opcode, len, payload…]` (no header byte) |
| SP630E | RGB(CW) SPI/PWM combo, reconfigurable | `[0x53, cmd, key, 0x01, 0x00, len, payload…]` |
| SP631E–SP63AE, SP641E–SP64AE | single-function SPI or PWM | same 0x53 frame as SP630E |

The SP63xE/SP64xE series is the current line: SP63xE = BLE-only, SP64xE =
dual-mode (BLE + Wi-Fi) counterparts of the same eleven functions (mono, CCT,
RGB, RGBW, RGBCCT in PWM and SPI variants). Model IDs 0x1F–0x35 in the
manufacturer-data advertisement map to these models (table in the device spec).

## Known facts (from app 3.3.2 static analysis + UniLED)
- GATT service `0000ffe0-0000-1000-8000-00805f9b34fb`, write characteristic
  `0000ffe1-…` (write-without-response command channel + notifications),
  confirmed in the app and by UniLED for every BanlanX model.
- Discovery signal: BLE manufacturer-data advertisement, company id **20563
  (0x5053 = "SP" little-endian)**, payload `[model_id, 0x10]` for SP6xxE
  (per UniLED; not contradicted by the app).
- 0x53-framed family: header byte 0x53 ('S'), cmd at offset 1, key at offset 2
  (0x00 = plaintext; nonzero = encrypted payload, unsupported by UniLED),
  fixed bytes 0x01 0x00, payload length at offset 5. Notifications with message
  type 0x02 carry a ~53-byte device-status payload (firmware string at
  data[11:18], light-type config at data[19], power at data[29], mode data[32],
  effect data[33], color/white levels data[35:42], speed/length/direction/gain
  data[42:46], static RGB data[47:50], CCT data[50:52]).
- OTA exists over BLE (custom, not Nordic DFU — no chip-vendor SDK libs in the
  app). Firmware check endpoint: `https://app.ledhue.com/spiot/device/check-update`;
  the .bin download URL is returned by that API (pattern not recovered).
- **NEW in app 3.3.2:** four 128-bit vendor characteristics
  `5833ff01..04-9b8b-5191-6142-22a4536ef123` with an authenticated channel
  ("ELS", endpoint `https://app.ledhue.com/spiot/els/v1`) carrying a
  seqAuth/clientAuth/serverAuth handshake vocabulary and encrypted session data.
  Not present in UniLED; algorithm and message format unmapped. MEDIUM
  confidence, static-analysis only.
- Dual-mode models (SP64xE) provision Wi-Fi via an ESP-style SoftAP at
  192.168.4.1 (2.4 GHz only), driven from the app's network-config flow.
- Cloud relay: `https://app.ledhue.com/spiot` (app check-update, manuals, Alexa
  linking). Local BLE control does not depend on any of it.

## Device discovery signals
- BLE manufacturer data: company id 0x5053; for SP63xE/SP64xE payload is
  `[model_id, 0x10]` with model_id 0x1F–0x35 (see device spec variant table).
  Older families match on the first manufacturer-data byte(s) instead
  (SP601E: 0x01; SP602E: 0x02; SP608E: 0x05 — per UniLED).
- Service UUID `0000ffe0-…` advertised.
- No advertised-name prefix strings were found in the app; UniLED identifies by
  manufacturer data, so treat local names like "SP630E" as a hint, not a key.
- Unresolved: `0000ff12/ff14/ff15-…` UUIDs present in the app, likely an
  accessory/remote family (service `0000ff10-…`), not SP6xxE.

## Threat model + guardrails
- Owned devices only. Legacy firmware accepts unbonded plaintext writes from any
  central in range — a privacy/annoyance consideration for the owner, not an
  attack surface to tool against.
- The ELS channel suggests the vendor is moving to authenticated sessions on new
  firmware; do not assume plaintext 0x53 writes keep working on future firmware —
  capture before relying on it.
- OTA: reference the vendor's public check-update endpoint only; never commit
  firmware binaries.

## Remaining experiments
1) **ELS channel (highest priority)** — HCI snoop or blutter Dart decompile of a
   first-pairing session on recent SP63xE/SP64xE firmware: handshake format,
   cipher, and whether plaintext 0x53 framing still works as a fallback (and in
   what order the app attempts the two).
2) Live-verify the UniLED-derived 0x53 command set and status layout on an
   SP630E (everything here is community-sourced, not captured by us).
3) Confirm the manufacturer-data discovery signal (`[model_id, 0x10]`) against a
   real advertisement; confirm whether local names follow the model number.
4) Resolve the roles of `0000ff12/ff14/ff15` and of each `5833ff0x`
   characteristic (write vs notify vs OTA).
5) Capture the firmware .bin URL returned by `/spiot/device/check-update` and
   document the OTA write flow.
6) Document the SoftAP provisioning exchange (192.168.4.1) for SP64xE dual-mode
   models — endpoints, credential format, and whether Wi-Fi control is local
   afterwards or cloud-relayed.

## Control surface inventory (replacement app MVP)
- scan + connect, matching on company id 0x5053 / service 0xFFE0, and decode
  model + capability config from the status notification (light-type byte
  selects SPI/PWM and channel count — do not hardcode per model)
- power, brightness, static RGB/CCT color, mode (static/dynamic/sound/custom)
  and effect select, effect speed/length/direction/play/loop
- audio input source + gain for music modes
- on/off (power-up) effect, on-power restore behavior, chip order, segment
  length
- light-type reconfiguration on SP630E (advanced: re-maps the output hardware)
- status parsing incl. firmware version; graceful handling of key != 0
  (encrypted) packets

## References
- UniLED (HACS) — primary protocol citation, five BanlanX modules:
  https://github.com/monty68/uniled (`custom_components/uniled/lib/ble/`:
  banlanx_601.py, banlanx_60x.py, banlanx2.py, banlanx3.py, banlanx_6xx.py)
- SceneX on Google Play: https://play.google.com/store/apps/details?id=com.spled.scenex
- Vendor docs/FAQ: https://document.ledhue.com/banlanx/faq/version/8/default
- Cloud base: https://app.ledhue.com/spiot (firmware check `/device/check-update`,
  ELS `/els/v1`)
