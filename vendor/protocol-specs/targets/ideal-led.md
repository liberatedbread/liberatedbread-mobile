# iDeal LED (com.tech.idealled) — target spec starter

## Target metadata
- target_id: ideal-led
- app package_id(s): com.tech.idealled (analyzed v3.0.4, versionCode 304, built 2025-02-26,
  minSdk 26 / targetSdk 34; distributed as XAPK with an arm64 native split)
- device class: addressable RGB pixel strings, curtain lights and pixel trees
  (Christmas-tree strings, curtain/waterfall lights, 25-lamp strings and similar
  Heaton-OEM products; firmware product codes TR21xx/TR22xx/TR23xx)
- transport(s): Bluetooth (BLE) only — the app contains no Wi-Fi/UDP/SoftAP/mDNS
  device path
- local-only viability: **high** — all control is local BLE with a static,
  publicly-documented AES key; the cloud only feeds the app's firmware check,
  BLE name-filter list and pattern library

## Family position
iDeal LED is one app in the Heaton OEM family that also ships as Magic Display,
Shining Glasses and the iDotMatrix companion apps. It shares the family's
16-byte `[len][ASCII opcode]` AES-128-ECB command framing and the
`d44bc439-abfd-45a2-b575-9254161296xx` characteristic set with
[Magic Display](../docs/devices/magic-display.md) and
[Shining Glasses](../docs/devices/shining-glasses.md), but runs on a JieLi
control chip (service `0xFFF0`, JieLi OTA service `0xAE00`) rather than the
Quintic/Panchip parts of its siblings, and speaks a string/tree-oriented
opcode set (SGLS/MULT/DOOD) rather than the panel opcodes. Cross-links:
`device-specs/devices/magic-display.yaml`, `device-specs/devices/idotmatrix.yaml`.

## Known facts (static analysis + open-source corroboration)
- Advertised-name prefix `IDL`; the app's scanner gates on the `0xFFF0` service
  UUID (in v3.0.4 the name-prefix filter is stubbed off, so the service UUID is
  the operative gate).
- Manufacturer-specific advertisement (AD type 0xFF) payload starts with
  `54 52 00 61` ("TR" + 0x0061); a scan-response filter matches the same prefix
  followed by `0x14`. Byte 6 = device group id, byte 7 = vendor/device id,
  bytes 11–12 = lamp count (uint16 LE).
- Service `0xFFF0`: write `…9600` (encrypted 16-byte commands), notify `…9601`
  (encrypted acks), read-version `…9602`, bulk write `…960a`, aux write `…960b`.
- Commands are 16-byte blocks: byte 0 = payload length, then an ASCII opcode
  (TURN, LIGHT, COLO, MODE, SPEED, SGLS, MULT, DOOD, SMVE, ANIM, IMAG, CONNECT,
  CONFIRM, LAMPQ, …), zero-padded, the whole block AES-128-ECB encrypted with
  the static family key published by 8none1/idealLED.
- Acks arrive encrypted on the notify characteristic and match plaintext ASCII
  after decryption: MULTOK, MULTCPOK, MULTREOK, SGLSOK, PLACPOK, PLAREOK,
  LAMPNMAX+val, LAMPNCANNOT, ERROR.
- Long payloads (multicolor lists, doodle frames, images) fragment as
  `[chunk_len+1][frame_index][data…]`, 96-byte chunks with a negotiated MTU
  (else 18).
- OTA is standard JieLi (jl_bt_ota SDK): service `0xAE00` / write `0xAE01` /
  notify `0xAE02`, `.ufw` container. 14 product-keyed `.ufw` images are bundled
  in the app assets; cloud check via `POST api.e-toys.cn/api/getFirmwareInfo`.
- Corroborated end-to-end by two open-source projects:
  [8none1/idealLED](https://github.com/8none1/idealLED) (published the AES key,
  ships btsnoop HCI captures, an `aes_decrypt.py` test tool and
  `att_protocol.md` protocol notes; working Home Assistant integration) and
  [koying/ha_ideal_led_ble](https://github.com/koying/ha_ideal_led_ble).

## Device discovery signals
- BLE advertised name prefix: `IDL`
- Service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- Manufacturer data (AD type 0xFF) prefix: `54 52 00 61`
  (company id 21076 = 0x5254, a squatted id spelling "TR" little-endian —
  see shining-glasses.yaml for the family precedent)
- Caution (8none1): devices exist that advertise as `IDL` or `ISP` lights but
  speak a **different** protocol — confirm the `0xFFF0` service and the
  `d44bc439` characteristics before assuming this spec applies.

## Threat model + guardrails
- Owned devices only. No bonding, no auth — anything in range can drive the
  string; that is a privacy/annoyance consideration, not an attack surface to
  tool against.
- **Brick hazard (real, documented):** the 8none1/idealLED author bricked one
  set of lights by sending out-of-family bytes during development
  (https://www.whizzy.org/2023-12-14-bricked-xmas/). A replacement client
  should stick to the documented opcode set and never fuzz the device.
- The AES key is static and public (8none1); it obfuscates, it does not
  authenticate. Recorded in the spec per the repo's recovered-key convention.

## Remaining experiments
1) **Live capture of the connect sequence** — order of CONNECT (handshake,
   +7B payload undecoded), CHECKLINE, CONFIRM (RGB channel order) and LAMPQ
   on first connect. Static analysis does not pin the order down.
2) Confirm whether the bulk channel (`…960a`) payloads are raw or ECB-encrypted
   (sibling Magic Display encrypts 16-byte blocks on its bulk channel; iDeal
   LED's 96-byte fragment format suggests raw — capture one MULT upload).
3) Confirm whether notify replies longer than 16 bytes are multi-block ECB.
4) Decode the SCHD (+8B) schedule layout, MIC/music-mode payloads, and the
   meaning of opcodes DEN / LEWPT / CALL parameters.
5) Map the `…9602` version characteristic's decrypted layout (version bytes
   observed at [6],[7] of a `52 00 61 82…` payload) across product types.
6) Identify the `IDL`/`ISP`-named off-protocol variants 8none1 warns about.

## Control surface inventory (replacement app MVP)
- scan (service UUID + `TR\x00a` mfr prefix) + connect, enable notify, optional
  MTU negotiation (96-byte bulk chunks vs 18)
- post-connect: CONFIRM RGB order, LAMPQ lamp-count query, version read
- power (TURN), brightness (LIGHT), solid color (COLO, note G,R,B order)
- mode (MODE/DIRECT), speed (SPEED), built-in effect select (SGLS, ack SGLSOK)
- multicolor segment effect (MULT header + fragmented RGB triplets, acks
  MULTCPOK/MULTOK/MULTREOK)
- doodle/freehand draw (DOOD pixels, DOOTCP completion)
- built-in animation/image select (ANIM/IMAG), DIY mode (SMVE)
- optional: JieLi OTA from app-bundled or cloud-fetched `.ufw` images

## References
- 8none1/idealLED (key publication, HCI captures, att_protocol.md, HA integration):
  https://github.com/8none1/idealLED
- koying/ha_ideal_led_ble (second HA integration): https://github.com/koying/ha_ideal_led_ble
- Bricked-lights writeup (guardrail evidence): https://www.whizzy.org/2023-12-14-bricked-xmas/
- iDeal LED on Google Play: https://play.google.com/store/apps/details?id=com.tech.idealled
- Firmware info endpoint (POST): https://api.e-toys.cn/api/getFirmwareInfo
- Sibling specs: device-specs/devices/magic-display.yaml,
  device-specs/devices/shining-glasses.yaml, device-specs/devices/idotmatrix.yaml
