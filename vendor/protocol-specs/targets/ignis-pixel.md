# Ignis Pixel — flow-arts pixel props target dossier

## Target metadata
- target_id: ignis-pixel
- app package_id(s):
  - com.ignispixel (Android, Qt6/QML; analyzed v2.29.9) — all protocol logic is in one
    symbol-rich native library; the Java/Kotlin layer is only a Qt shell
  - iOS equivalent exists (same vendor)
  - Desktop: IgnisPixelUtility (Windows exe / Mac zip), public on the vendor's update
    server; speaks the same bootloader protocol over USB
- device class: programmable LED flow-arts props — pixel poi, staffs, fans, buugeng,
  hoops, clubs, juggling props, jumpropes, lamps (~137 device types in the vendor's
  public firmware catalog)
- transport(s): Bluetooth (BLE, Nordic UART Service over an nRF52832 bridge);
  prop-to-prop sync over a separate nRF24L01+ 2.4 GHz radio (not BLE, not app-facing)
- local-only viability: high for connection + framing; the full command set is
  recoverable but the numeric opcode map has not been extracted yet (open item #1)

## The protocol is one native library away from complete
The app keeps zero protocol logic in bytecode — everything (framing, CRC, command
tables, OTA) sits in a single 25 MB shared object **with a full 73k-symbol table**,
which is why the framing, header layout and CRC parameters below are HIGH confidence
from disassembly alone. The one thing not yet done is walking the opcode literal
pools to turn ~70 recovered command names into numeric message IDs. Hardware:
STM32F103/F411 main MCU + nRF52832 BLE bridge + WS2812 pixels; Wireless-Sync "I"
models add the nRF24 radio.

## Known facts (from app analysis + live server)
- BLE profile: Nordic UART Service `6e400001-…`; phone writes `6e400002-…` **with
  response**, subscribes to `6e400003-…` (CCC `0x2902`). The app's BLE scanner
  filters on the NUS service UUID only — no name-prefix filter.
- Framing: `0xFF` start, payload with `0xFF` escaped as `FF FE`, `FF FF` end; no
  length field; a packet is complete when it ends in `FF FF`.
- Header: 8 bytes — type u8, time u32 LE, CRC16 u16 LE, reserved u8. CRC16-CCITT
  (poly 0x1021, init 0, MSB-first, no final XOR) over the message with the checksum
  field zeroed; separate CRC32 (init 0) for image/firmware data blocks.
- Requests are 13 bytes: reserved=1, command id at offset 8, u32 LE argument, CRC16
  filled in, then framed. Header type for PC→device requests appears to be 0
  (MEDIUM — confirm against one capture).
- ~21 inbound message structs (MSG_ACK/MSG_HW_INFO/MSG_UID/…); MSG_HW_INFO reports
  MCU/RF/IMU/flash types, radio freq/group/mode, battery, FW_Ver (u32, e.g.
  0x03002100 = v3.0.33) and FW_DevType (u16 model id, matches Update.xml `Type=`).
- OTA: GO_BURN → FIRMWARE_ERASE → MSG_DATA_BL blocks (per-block CRC32, addressed by
  file offset; header/data pair) → GOTO_MAIN.
- Firmware is **public**: `Update.xml` catalog + `hash.md5` manifest (~1600 files),
  release `.fw` images per model, desktop updater — all plain HTTPS, no auth.
- Wireless Sync (vendor FAQ): 13 channels × 32 groups, configured on the prop's
  system menu; one prop controls its group over nRF24. `CM_SWITCH_RF` /
  `SAVEINTERNALRADIO` toggle a prop between BLE control and RF-slave mode; BLE
  returns after power-cycling unless the radio mode was saved.

## Device discovery signals
- Advertised service UUID: `6e400001-b5a3-f393-e0a9-e50e24dcca9e` (Nordic UART
  Service) — the **only** signal the vendor's own scanner uses.
- Advertised local name: **not yet captured** — record it on first hardware contact.
- WARNING: NUS is a shared platform UUID (countless UART-bridge gadgets advertise
  it). Confirm identity after connecting via the get-id / hardware-info request and
  the FW_DevType field before claiming a match.

## Threat model + guardrails
- Owned devices only. Props accept any central in range with no pairing, PIN or
  encryption — and the same unauthenticated surface exposes firmware erase/reflash.
  Note that as a performer/owner consideration (anyone nearby can hijack a show
  prop), not an attack surface to tool against.
- The RF sync link (nRF24) is equally unauthenticated by design; groups are
  separated only by channel/group numbering.
- OTA commands are marked `advanced` in the spec: an interrupted or wrong-model
  flash bricks the prop until the desktop-utility recovery.

## Remaining experiments
1) **Extract the numeric opcode map** — highest priority and purely static work:
   script a pass over the address-computation/load pairs in the app's native
   command-dispatch functions where opcode constants sit beside command-name string
   comparisons. Turns every symbolic command in the spec into bytes.
2) **First live capture** (HCI snoop or nRF Connect): connect → get-id → set
   brightness → upload one small image. Confirms the request-envelope hypothesis
   (type=0 / reserved=1), the NUS write chunking/MTU behavior for bulk transfers,
   and the advertised local name.
3) Map MSG_DATA_ONE/_DBL image-block layout (R/G/B u32 channels, gamma step, color
   order) and MSG_PC_CMD_EX (ArgA–D/AckCodeA–D) field widths.
4) Check whether release `.fw` files are obfuscated (download one from the public
   server, inspect the header) before writing an independent flasher.
5) nRF24 on-air capture of the sync protocol (the shared framing routine's name
   suggests the FF-framing is reused on RF).

## Control surface inventory (replacement-app MVP)
- scan + connect (NUS filter), then confirm identity via get-id / hardware-info —
  never trust the NUS advertisement alone
- brightness, display mode selection (ball / creeping line / swing / volchok /
  player), duration
- image/timeline upload with device-paced writes (the core value of the product:
  what the prop renders while spun)
- battery level + firmware/device-type readout (MSG_HW_INFO)
- alarm / off-timer, run-on-start and stillness behaviors (CM_SETTINGS_*)
- RF sync group configuration (channel 1–13, group 1–32) and group actions
  (sleep/wake/find-me) for Wireless-Sync models
- firmware update against the public Update.xml catalog, with model matching on
  FW_DevType and desktop-utility recovery documented
- local storage of uploaded image sets so a show survives an app reinstall

## References
- Firmware catalog (public, verified live): https://software-upload.ignispixel.com/Update/Update.xml
- File manifest: https://software-upload.ignispixel.com/Update/hash.md5
- Desktop updater: https://software-upload.ignispixel.com/Update/Software/IgnisPixelUtility_Win.exe
- Vendor FAQ (Wireless Sync 13×32, recovery flow): https://ignispixel.com/faq/support
- Vendor downloads (manuals, software, picture sets): https://ignispixel.com/downloads
- App on Google Play: https://play.google.com/store/apps/details?id=com.ignispixel
- Machine-readable spec: `device-specs/devices/ignis-pixel.yaml`
