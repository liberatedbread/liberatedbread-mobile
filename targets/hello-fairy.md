# Hello Fairy (Avatar Controls) — target dossier

## Target metadata
- target_id: hello-fairy
- app package_id: `com.lenzetech.hellofairy` (Hello Fairy, v3.3.3 analyzed; a
  separate vendor "Hello Fairy OTA" companion app exists for resuming interrupted
  firmware updates)
- device class: app-controlled addressable RGB(W) light strings — fairy/string
  lights, curtain lights, Christmas-tree lights (some with tree-top star), wall
  "painting" lamps; solar and battery SKUs exist
- transport(s): Bluetooth (BLE) only — the app contains no UDP/TCP/SSDP/mDNS/
  SoftAP code and no Wi-Fi provisioning
- local-only viability: **high**. BLE is the entire control surface; the cloud
  is used only for firmware images, scene artwork and telemetry

## Known facts
- Advertised name **contains "Hello Fairy"**; the app's BLE scanner filters on
  exactly that substring (devices mid-OTA are exempted and matched by MAC).
- Control service is ISSC/transparent-UART style:
  service `49535343-fe7d-4ae5-8fa9-9fafd205e455`,
  write `49535343-8841-43f4-a8d4-ecbe34729bb3`,
  notify `49535343-1e4d-4bd9-ba61-23c647249616` (enable notify first).
- Framing: `[0xAA][cmd][len][payload][sum8]`; sum8 covers the head byte.
  A `[0xBB][cmd][len32 BE][payload][0xBB]` variant exists for bulk file
  transfer (cmd 0x33; cmd 0x01 is a headerless `[0xBB][payload]` special case).
  All multi-byte payload fields are big-endian.
- ~70 opcodes; the mapped control surface: 0x00 device info, 0x01 status,
  0x02 power, 0x03 light mode (warm-white/HSV/scene/music), 0x04 countdown,
  0x05 set-time, 0x06/0x07 schedule timers, 0x09 battery, 0x0A series/segments,
  0x0B power mode, 0x0C scene speed, 0x14 current limit, 0x30-0x33 file/DIY
  transfer; 0xA0-0xE0 device→app events.
- No link crypto and no bonding; integrity is sum-8 only. A device-lock
  ("password") UI module exists but its wire mechanism is untraced.
- Three firmware families across SKUs: **Lenze ST17H66** (OTA service
  `5833ff01-…ff04`, MAC+1 re-advertise in OTA mode, CRC16/MODBUS partitions,
  Intel HEX images), **ESP32** (Nordic-DFU-style `1d14d6ee-…` / `f7bf3564-…`,
  raw .bin), **Bluetrum** (.fot images, OTA transport unmapped).
- Firmware is **public**: plain-JSON manifest
  `https://hellofairyota.s3.amazonaws.com/hello_fairy_ota_pro.json` keyed by
  the model string from GetDeviceInfo (e.g. "BMSL64"); 47 images harvested
  during research (not committed — re-fetch from the manifest).

## Device discovery signals
- BLE advertised name: contains `Hello Fairy`.
- Service `49535343-fe7d-…` present → normal control identity.
- An address one higher than a known device's MAC advertising the OTA service
  `5833ff01-…` → that device is sitting in ST17H66 OTA mode (stuck or
  mid-update); reverse is MAC−1.
- GetDeviceInfo (0x00) is the model oracle: model string + Device_Type/DIY_Type
  + capability TLVs, and the same model string keys the OTA manifest.

## Threat model + guardrails
- Owned devices only. These strings connect without bonding and accept commands
  from anyone in range — note as a privacy consideration (a neighbor can see
  and drive your lights), not an attack surface to tool against.
- The OTA path writes flash. Only flash images from the vendor's public
  manifest that match the device's model string; the ST17H66 flow is
  interruptible (MAC+1 identity persists for resume) but a partial flash is
  still a recovery situation.
- `set_limiting_value` (0x14) raises the driver current limit — treat as an
  advanced operation; read and save the current value first.
- Privacy flags on the vendor app (not needed for local control): it POSTs
  device telemetry (MAC, model, firmware, GATT UUID list) to a vendor backend
  at `121.40.220.76:20003`, and fetches cloud-storage credentials from a
  vendor endpoint at runtime.

## Remaining experiments
1) **Live HCI snoop of the basics** — connect → get_device_info →
   get_device_status → power → HSV color → scene. Everything in the spec is
   statically derived; nothing is wire-verified yet.
2) Map the 0xA0-0xE0 device→app event opcodes by exercising the hardware
   (power button on the controller, timer firing, tree-top star toggle).
3) Transcribe the remaining opcode payloads (0x0D-0x0F pairs, 0x11-0x13,
   0x19, 0x20, the 0x30/0x32 sub-command layouts) and verify the 0x0A
   segments vs devices-in-series ambiguity (two parsers share the opcode).
4) Trace the device-lock password feature: is there a link-level password
   command, and does a locked unit reject unauthenticated writes?
5) DIY/GIF file transfer end-to-end: 0x30 file-info handshake → 0x31/0x33
   data chunks → 0x32 save/play; capture one small upload.
6) Bluetrum (.fot) OTA transport — the majority of manifest images are .fot
   but no OTA code path for them was found in the app.
7) ESP32 OTA details (the {3}/{0} start writes and chunking) and the exact
   byte order of ST17H66 partition headers.

## Control surface inventory (replacement app MVP)
- scan (name contains "Hello Fairy") + connect, enable notify first
- get_device_info → model, LED count, capabilities; get_device_status
- set_time on connect (device-side timers depend on it)
- power on/off; HSV color; scene select + scene speed; warm-white on RGBW SKUs
- countdown timer; schedule timers 1-8 (read-modify-write 4-byte records)
- battery level (battery SKUs)
- stretch: DIY/GIF upload (0x30-0x33), OTA from the public manifest

## References
- Hello Fairy on Google Play: https://play.google.com/store/apps/details?id=com.lenzetech.hellofairy
- Public OTA manifest (firmware for all three chip families): https://hellofairyota.s3.amazonaws.com/hello_fairy_ota_pro.json
- Vendor scene/UI resource bucket (app assets, not needed for control): https://hellofairyapp.s3.amazonaws.com/
- Historical APK versions page: https://d225sgx93xedrp.cloudfront.net/hellofairy_download/apk/HelloFairy_historical.html
- Device spec: `device-specs/devices/hello-fairy.yaml` (protocol detail)
