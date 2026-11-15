# Astral Hoops Atomic V (AF series) — target dossier

## Target metadata
- target_id: astral-hoops
- app package_id: com.astral.astral ("Astral"), v2.0.16 / versionCode 36 analyzed
- device class: programmable LED flow props — hula hoops, wands, fans (Atomic V / AF series)
- transport(s): Bluetooth (BLE) only
- local-only viability: **high** — the app has no account system, no ad/analytics SDKs, no
  crypto; every function (modes, speed/hue, settings, pattern upload, firmware OTA) runs over
  the BLE UART. Network use is limited to public, unauthenticated HTTPS downloads of firmware
  images and pattern packs, which this project can mirror.

## Known facts (app analysis)
- The app is small and unobfuscated (Java, ~26 classes), no native libraries, no packing.
- Devices advertise as `Atomic` + a 5-character unit ID (`AtomicNNNNN`); the scanner filter is
  name length ≥ 6 with the first 6 characters equal to `Atomic`.
- Transport is the Microchip/ISSC Transparent UART BLE module (public ISSC UUIDs):
  service `49535343-FE7D-4AE5-8FA9-9FAFD205E455`, TX (write)
  `49535343-1E4D-4BD9-BA61-23C647249616`, RX (notify)
  `49535343-8841-43F4-A8D4-ECBE34729BB3`. No MTU negotiation; bulk paths use 16-byte GATT
  writes with ~10 ms spacing.
- Protocol is ASCII: `#`-commands app→device, `&`-records plus `OK`/`BL`/ACK(0x06)/CAN(0x18)
  device→phone. Full inventory in `device-specs/devices/astral-hoops.yaml`.
- The app can hold several props connected at once and broadcasts each command to all of them
  (synchronized group control = N GATT links, same bytes).
- Pattern upload: `#D` handshake → 10-byte header → gamma-corrected RGB888 in 20-byte chunks,
  each ACKed `OK` → final slot-number byte. Persists on the device; `#WIPE` clears
  customizations, `#FORMAT` reformats pattern storage.
- MCU is a Microchip/Atmel SAM D21 (Cortex-M0+): the OTA updater verifies the Cortex-M0+ CPUID
  (0x410CC601) and the SAM D21 Device ID register (0x10010305 at 0x41002018) through the
  bootloader before flashing.
- Firmware is **public**: `https://astralhoops.com/images/a5.ver` (returned `5.2.5` when
  fetched; beta `a5beta.ver` = `5.3.0`) and `af5.bin` / `af5beta.bin` — raw flash images loaded
  at offset 0x2000 behind an 8 KB custom bootloader. OTA runs over the BLE UART with a
  `#`-terminated bootloader command language (word/halfword/byte writes staged to RAM 0x5000,
  committed per 0x1000-byte page) plus an apparently legacy XMODEM-CRC16 block path.
- Pattern gallery: `https://extras.astralhoops.com/patterns/` — `folders.php` pack list,
  `<pack>/folders.php`, `<pack>/patterns.php?folder=<f>`, raw-byte pattern file downloads.
- Dead leftover Bluetooth Classic SPP code exists in the app but is never connected; there is
  no Wi-Fi, UDP, SSDP, mDNS or SoftAP path.

## Device discovery signals
- BLE advertised name: `Atomic` prefix (full form `AtomicNNNNN`).
- Service UUID `49535343-fe7d-4ae5-8fa9-9fafd205e455` (ISSC transparent UART).
- Note: the ISSC UART UUIDs are shared by many unrelated products — match on the `Atomic`
  name prefix, not the service UUID alone.

## Threat model + guardrails
- Owned devices only. Props accept a connection from anyone in range (no bond, no PIN) —
  a wearer-privacy consideration (a third party could change patterns or wipe customizations),
  not an attack surface to tool against.
- The OTA path is powerful (full flash rewrite with no image authentication). Document it so
  owners can reflash abandoned hardware; do not ship tools that push firmware to devices
  without the owner's explicit action. An interrupted erase (`X00002000#`) leaves the prop
  inoperable until a valid image is flashed.
- No keys or secrets exist in this target: the app contains no crypto, and firmware updates
  are unsigned public downloads — nothing to withhold, nothing to redact.

## Remaining experiments
1) **Live capture of the settings chain and `&`-records** — confirm the `#GV`/`&V` reply
   layout (the parser has both an `&V<string>` branch and a 0x05-led binary-triplet branch),
   the `&M` payload field semantics (mode/group/speed/hue), and whether `#SS` takes an ASCII
   or binary operand.
2) **Mode/item index tables** — they live in app UI resources; capture `#SM2=` traffic while
   stepping through the app's mode list to build the index map.
3) **Replay the OTA sequence on a sacrificial unit** — verify the word-writer path end to end
   and determine whether the XMODEM block path is still exercised by any current flow.
4) **Image upload details** — confirm the header's width/height padding and recover the exact
   256-entry gamma table from a capture if bit-exact colors matter.
5) Probe the pattern gallery `folders.php` / `patterns.php` response formats (plain newline
   lists per the app code, unverified beyond one 46-byte `folders.php` response).

## Control surface inventory (replacement app MVP)
- scan (`Atomic` prefix) + connect, enable RX notifications, walk the `#GS→…→#GN` settings chain
- mode + menu-item selection (`#SM2=`), custom speed + hue (`#SM3=`)
- battery level display (`&L`, 0-7 steps) and mode/state tracking from pushed `&` records
- settings: LED count/type, battery type, prop type, sleep timeout, POV stabilization
- pattern upload with device-driven ACK pacing, pattern slot preview (`#V`+byte), wipe/format
- optional: firmware OTA from the public `af5.bin` URLs
- optional: multi-prop synchronized control (fan every command out to all connections)
- local pattern storage that survives an app reinstall; import from the public pattern gallery

## References
- Astral Hoops: https://astralhoops.com/
- AF-series instructions: https://shop.astralhoops.com/pages/instructions-af
- Firmware version/image (release): https://astralhoops.com/images/a5.ver ,
  https://astralhoops.com/images/af5.bin (beta: a5beta.ver, af5beta.bin)
- Pattern gallery: https://extras.astralhoops.com/patterns/
- Astral app on Google Play: https://play.google.com/store/apps/details?id=com.astral.astral
