# Cobra iRadar / iRAD radar detectors — Research Notes

## What it is
Bluetooth-enabled radar/laser detectors (iRadar S120R, iRAD 900/950, SPX
7800BT, DualPro 360 BT features, etc.) that stream alerts and take settings
over **Bluetooth Classic RFCOMM (standard SPP UUID)** from the "Cobra iRadar"
phone app. Manufacturer Cobra/Cedar Electronics is alive, but the iRadar
app/platform is discontinued:
- https://support.cobra.com/support/solutions/articles/47001281704-iradar
  ("iRadar has been Discontinued. Users should switch to our Drive Smarter app")
The detectors themselves work standalone; the app adds GPS lockouts, settings,
and the (cloud) AURA camera database. Local control needs no account.

## APK provenance
- **Package**: `com.cobra.iradar` (codebase is `com.escortLive2.*` — Cedar
  merged Cobra/Escort app stacks)
- **Version**: 5.1.80 (versionCode 142), bare APK, 33 MB
- **SHA-256**: `28ccb34e0b941b359b76b6b90e7bea59cc465102fd36fd7a81e66682f68a11e5`
- **Source**: apkeep / apk-pure, 2026-08-04
- jadx triage → `$REPO/workspace/static/cobra-iradar/`

## Static findings (triage)
- `com/escortLive2/bluetooth/ConnectAsClientThread.java`: RFCOMM via
  `createInsecureRfcommSocketToServiceRecord` with **SPP UUID
  `00001101-0000-1000-8000-00805f9b34fb`** (insecure socket — no pairing auth
  dependency beyond standard pairing).
- `com/escortLive2/bluetooth/protocol/PacketProcessing.java`: frame parser
  keys on byte value **85 (0x55)** as preamble — matches community RE below.
- `UartService.java` also present (some newer detectors are BLE; the iRAD 900
  generation is classic SPP — verify per model).

## Community RE: protocol documented
`github.com/brandonasuncion/Reverse-Engineering-Bluetooth-Protocols` (2017,
MIT) — full write-up + Python client for the iRAD 900:
- Detector → phone frame every ~0.5 s: preamble `0x55`, 2-byte payload size,
  action byte, SEQ byte, alert flag (`0x41` = alerting) + alert-type byte.
- Phone MUST ACK each frame: 9-byte response, action `0x02`, ACK = last SEQ,
  plus a decrementing counter; detector disconnects if ACKs stop.
- Initial connect does a settings sync (recorded, replayable; repo ships
  `.pklg` captures + replay script).

## Local feasibility: CONFIRMED (moderate)
Plain RFCOMM, no auth, published frame format, reference Python client.
An ESP32/RPi/Linux host can receive alerts and hold the session open today.
Settings-write opcodes are less documented (initial-sync replay is the known
path) — a live capture while toggling settings in the APK would close that gap.

## Open questions
- Per-model transport split (classic SPP vs BLE `UartService` path).
- Settings write opcode map.
- Does Drive Smarter-era firmware change the frame layout?

## Safety/legal
Receive-only detector; no vehicle bus. Radar detectors are illegal in some
jurisdictions (and detectors-with-app features restricted e.g. France). LOW.
