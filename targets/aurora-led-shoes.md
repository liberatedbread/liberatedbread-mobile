# Aurora LED Shoes (com.jtkj.auroraled) — target spec starter

## Target metadata
- target_id: aurora-led-shoes
- app package_id: com.jtkj.auroraled ("Aurora LED Shoes" / "AuroraLed", versionName 1.0.1,
  versionCode 2, minSdk 18, targetSdk 29 — sourced from the APKPure XAPK)
- device class: light-up rave shoes / LED footwear (BLE-controlled RGB LEDs in the sole)
- transport(s): Bluetooth (BLE) only — no Wi-Fi/UDP/TCP/SSDP/mDNS/SoftAP code in the app
- local-only viability: **high**. No handshake, no pairing, no checksum, no crypto, no OTA, no
  vendor backend. The only non-SDK HTTP in the app is a connectivity probe; the remaining
  network code is Umeng analytics. The shoes work fully offline once you can speak BLE.

## Same developer family as CoolLED1248 — different profile
The app developer (jtkj) also ships CoolLED1248 (com.jtkj.led1248). Both apps share the same
BLE wrapper library and the same "list of hex-string bytes" command-building idiom, **but the
GATT profile and opcode set are different**: CoolLED1248 is the 0xFFE5/0xFFE9 family, Aurora
LED Shoes is 0xFFF0/0xFFF1 with its own tiny opcode table. Do not assume cross-compatibility —
each jtkj app must be reverse engineered individually.

## Known facts (from static analysis of com.jtkj.auroraled v1.0.1)
- Unobfuscated app code, single classes.dex, no packer, no native libs, no assets. jadx
  decompile succeeded cleanly.
- GATT: service 0xFFF0, single characteristic 0xFFF1 used for **both write and notify**
  (notify enabled ~500 ms after connect via CCC 0x2902). Writes are write-without-response,
  auto-split at MTU.
- Command framing: raw opcode-first packets, 1–4 bytes each, one GATT write per command.
  No header, no length, no checksum, no encryption.
- Commands: `01 R G B` music/mic-reactive color · `03 R G B` solid color · `04` toggle power ·
  `05 V` set power (V=00/01) · `07 SS PP [PP]` pattern/mode select (sub-table below) ·
  `10 V` pattern speed · `F0` state query → notify `F0 FLAG SPEED` (FLAG 00/01 = power,
  SPEED 0–255 echo).
- Mode sub-table (opcode `07`):
  - `07 04 NN` slow color change: NN = 00 blue, 01 green, 02 red, 03 cyan, 04 purple,
    05 yellow, 06 white, 20 seven-color cycle, 30 red+green, 40 red+blue, 50 green+blue
  - `07 05 NN` flash: NN = 00 blue, 01 green, 02 red, 03 cyan, 04 purple, 05 yellow,
    06 white, 10 seven-color
  - ten additional "shining" effect presets (fixed byte strings: `07 06 01 00`, `07 01 08`,
    `07 01 13`, `07 03 01 00`, `07 09 00`, `07 09 01`, `07 0A 01`, `07 0A 02`, `07 01 01`,
    `07 02 00`) — exact visual semantics unknown
- Music mode: all signal processing is on the phone (mic → FFT, 35 bins, peak pick per
  11-bin third → RGB). The shoe just displays `01 R G B` writes live — a replacement app
  can feed it any color stream.
- **Multi-shoe broadcast**: the app keeps several shoes connected simultaneously and sends
  every command to all of them. A replacement client should do the same.

## Device discovery signals
- BLE advertised name: prefix **`FS`** (exact, case-sensitive prefix match in the app's
  scanner). Full advertised name unconfirmed — could be exactly `FS` or `FS-XXXX`;
  needs a live scan.
- Advertised service UUID: `0000fff0-0000-1000-8000-00805f9b34fb` (0xFFF0).
- The app's scanner requires **both** signals: name prefix `FS` AND service 0xFFF0.
- Connection behavior: 5 s scan timeout, no auto-connect at scan level; reconnect 5 attempts
  1 s apart, 5 s connect timeout. The app auto-reconnects to previously-connected MACs from a
  locally cached list (no cloud involved).

## Threat model + guardrails
- Owned devices only. The shoes accept connections and commands from any central in range —
  no bonding, no authentication. Note this as a wearer consideration (anyone nearby can change
  your shoes' colors), not an attack surface to tool against.
- Only one central can hold the link at a time per shoe; the remedy for "won't connect" is
  usually that the vendor app on another phone is still connected.

## Remaining experiments
1) **Live capture of the speed command** (`10 V`): the app computes the on-wire value as
   `seekbarMax - (progress + 15)` with a persisted default of 120 and a device-side hint of
   ~15 steps, but the seekbar max was in app resources that weren't decompiled. Pin the real
   range and direction (lower appears to mean faster — inverted slider).
2) Map the ten `07 ...` "shining" presets to their actual visual effects (send each, film the
   shoe).
3) Confirm whether the `F0` state query is actually sent by the app or dead code; capture the
   `F0 FLAG SPEED` notify frame on a live unit (does it also arrive unsolicited on power
   toggle?).
4) Live scan for the full advertised device name and MAC OUI.
5) Identify the BLE module (0xFFF0/0xFFF1 serial-bridge style is typical of cheap BLE-UART
   modules); no SDK markers in the app, so this needs hardware.

## Control surface inventory (replacement app MVP)
- scan for name prefix `FS` + service 0xFFF0, connect (no pairing), enable notify on 0xFFF1
- maintain multiple simultaneous shoe connections; broadcast every command to all of them
- power: toggle (`04`) and explicit on/off (`05 01` / `05 00`)
- solid color picker (`03 R G B`)
- pattern modes: slow color change (`07 04 NN`), flash (`07 05 NN`), the ten shining presets
- speed slider (`10 V`) — inverted, lower = faster
- music-reactive mode: phone mic → color stream of `01 R G B` writes (all DSP client-side)
- state readout: query `F0`, display `F0 FLAG SPEED` notifications

## References
- Aurora LED Shoes on Google Play: https://play.google.com/store/apps/details?id=com.jtkj.auroraled
- CoolLED1248 (sibling jtkj app, different profile): https://play.google.com/store/apps/details?id=com.jtkj.led1248
- FastBLE (the open-source BLE wrapper both apps use): https://github.com/Jasonchenlijian/FastBle
