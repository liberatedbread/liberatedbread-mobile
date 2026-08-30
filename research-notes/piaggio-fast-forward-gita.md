# Piaggio Fast Forward gita robots — Research Notes

## What it is
Piaggio Fast Forward (PFF), a Boston subsidiary of the Piaggio Group, builds
cargo-carrying following robots: **gita** (2019, $3,250, 40 lb cargo), **gitamini**
(2021, $1,850, 20 lb, adds radar), **gitaplus**, and the Star Wars licensed
**G1T4-M1N1** (2026). The robot visually follows its owner; the companion app
**mygita** (`com.piaggiofastforward.mobile`) handles pairing, naming, battery
status, speaker control, and software updates.
([The Verge on gitamini](https://www.theverge.com/2021/9/22/22685649/gita-gitamini-cargo-carrying-robot-piaggio),
[piaggiofastforward.com](https://piaggiofastforward.com/)).

## Why it's here
The company is **not** defunct — this is pre-positioning. The architecture is
more cloud-coupled than it first looks: app↔robot registration issues a BLE
session key through the vendor cloud, and firmware OTA downloads come from
JWT-gated endpoints fetched by the robot itself. If the cloud ever goes away,
new-phone pairing and firmware updates go with it. Documenting the local BLE
protocol now is the hedge.

## Local BLE feasibility
- Following itself is on-robot machine vision — no radio needed while walking.
- All interactive control is **local BLE GATT**; there is no SoftAP and no
  local HTTP interface. Robot Wi-Fi (provisioned over BLE) is used only for
  OTA, log upload, and the fleet MQTT channel.
- One encrypted command channel (AES-128-CBC keyed by an ECDH secp256k1
  handshake done over GATT) carries ~40 opcodes: Wi-Fi management, speaker/
  mute/volume, stealth, latch, software download/install, uptime, log push,
  OTA status, autonomous-behavior toggle, and enable/disable of the robot's
  **SSH daemon** (ops 101/102 — a promising local-control path on real
  hardware, credentials unknown).
- The BLE advertisement already leaks serial, battery, model, and status in a
  TLV under company ID 0x083B ("Piaggio Fast Forward") — a scanner can
  inventory robots without connecting.

## Protocol summary (from mygita v1.7.2 JS bundle)
- Scan filter: 16-bit service UUID `0x9999`. Sole GATT service
  `87654321-1234-5678-1234-56789abcdef0`, characteristics `…def1`–`…defb`
  (auth, encrypted CMD, Wi-Fi status, identity, ECDH pubkey in/out, main
  notify, version, registration, session key). MTU 185, write-no-response.
- Framing: `[opcode][0x7F][data…]`, AES-128-CBC/PKCS7 whole-buffer,
  ciphertext chunked in 181-byte frames + 1 end-flag byte.
- Registration/session-key channel is cleartext ASCII framed with
  `##<10-char id>` and `$$$$$` / `#####` suffixes.
- OTA: `GET https://api.mygita.com/ota-v2-check?gitaId=…&buildId=…` →
  `/ota-v2-infos/<id>` (both JWT-gated, verified 400 unauthenticated) →
  BLE ops 85 (download) / 80 (install). No firmware image is publicly
  fetchable without an account and a registered robot.
- Open `/info/version` endpoint (2026-08-29): API 1.16.21, min supported
  mygita app 1.4.5.

## APK details (apkeep, apk-pure)
- Package: `com.piaggiofastforward.mobile`, version 1.7.2 (versionCode
  5254319), minSdk 28 / targetSdk 35. React Native; protocol logic lives in
  the plain-JS (non-Hermes) bundle — native layer is stock libraries.
- XAPK SHA-256: `c8f4a09732036b20ecba730da76c826855f1cdfd469ece6cfbb8a069d8320641`
- Full analysis + evidence: `~/research/piaggio-fast-forward/`
  (`RESEARCH.md`, `FINDINGS.md`, bundle, jadx output). Note the bundle
  carries PFF copyright headers — facts only, no code reuse.

## Hardware/regulatory pointers
- FCC grantee code **2AY6H** (Piaggio Fast Forward, Inc): known filings
  2AY6H-101440 "Blind Spot Information System" and 2AY6H-101572 "FCW Radar
  System" (perception radar modules). Robot-body filings not yet pulled —
  fccid.io and device.report block non-browser clients.
- User manual on ManualsLib: "PIAGGIO gita"
  ([manual 2132818](https://www.manualslib.com/manual/2132818/Piaggio-Gita.html));
  fetch with a browser UA or via archive.org.

## Open questions
- Firmware image capture: sniff a real OTA (account + registered robot) to
  learn the actual download URL/host, or enter via the BLE-gated SSH daemon
  and dump the filesystem.
- Per-op payload layouts and notification semantics (types 100–126, 140, 141;
  multipacket flags 251–255) — one HCI snoop of "connect + one action".
- Whether BLE pairing can be completed fully offline (local ECDH path) without
  the cloud-issued session key — the dead passcode constant in the app's BLE
  config hints at a legacy local pairing path.
- FCC internal photos/schematics for a hardware map.
