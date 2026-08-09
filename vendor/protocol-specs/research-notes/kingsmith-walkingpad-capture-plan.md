# KingSmith WalkingPad — Hardware Capture Plan

Purpose: close the open protocol questions in
`device-specs/devices/kingsmith-walkingpad.yaml` that static APK analysis
(2026-08-08) could not resolve. Each capture below is mapped to the question
it answers.

## 0. Finding the device on first scan (BLE advertising facts)

- **No pairing, no bonding, no encryption** on either protocol generation.
  Any central can connect; nothing to enter, nothing to forget afterwards.
- **Power the pad on** with its physical remote or side switch — it
  advertises whenever it is on and not connected.
- **Advertised name prefixes** (from KS Fit v6.5.6 / WalkingPad v2.5.5 string
  tables and prior art): `WalkingPad*`, `KS-R1*`, `KS-MC21-*`, `KS-SMC21C-*`,
  `ZP-ZEALR1-*`, `KS-HD-*` (e.g. `KS-HD-Z1D`), `KS-X21*`, `DYNAMAX*`,
  `KINGSMITH*`.
- **Advertised service UUID tells you the protocol generation**:
  - `0000fe00-0000-1000-8000-00805f9b34fb` → legacy WiLink (A1/A1 Pro/R1/R2/early C2)
  - `00001826-0000-1000-8000-00805f9b34fb` → FTMS generation (MC21/X21/KS-HD-*)
- **Single-connection peripheral**: only one BLE central at a time. Before
  capturing, force-close the official KS Fit / WalkingPad apps on every
  nearby phone and disconnect the pad's own remote linkage, or your client
  will fail to connect.
- Note the pad's BLE MAC and exact advertised name on first scan — Android
  masks MACs in `dumpsys bluetooth_manager`, so record it from the scanner.

## 1. GATT table dump — nRF Connect (15 min, no snoop needed)

Tool: nRF Connect for Mobile (Android/iOS).

1. Scan, filter by name prefix or service UUID above; connect.
2. Export/screenshot the full service/characteristic table incl. properties
   and CCCDs.

Answers:

- **ODM parent service UUID** (open question, confirmed absent from both app
  binaries 2026-08-08): if characteristic
  `d18d2c10-c44c-11e8-a355-529269fb1459` exists, record **which service it
  sits under** (128-bit vendor service vs. inside 0x1826).
- **Supplement service layout** (KS-HD-* only): properties (write /
  write-without-response / notify / indicate) of all four characteristics
  `24e2521c-f63b-48ed-85be-c5330{0b,0d,0e,0f}00fdf7`, and whether 0e/0f
  actually exist on the pad or are just app-side table entries.
- `0x2ADA` properties and whether other FTMS chars (0x2AD0–0x2AD8) are
  populated.
- Read `0x2AD4` (Supported Speed Range) and DIS strings (0x2A24 model,
  0x2A26 firmware) — record firmware revision for the spec.

## 2. Android HCI snoop of the official app (main capture)

Setup:

1. Android phone with KS Fit installed → Settings → Developer options →
   **Enable Bluetooth HCI snoop log**.
2. Toggle Bluetooth off/on to start a clean log.
3. Force-close all other BLE apps; keep this phone the only central.
4. After the session, pull the log: `adb bugreport` (log lands at
   `FS/data/misc/bluetooth/logs/btsnoop_hci.log` inside the report; on some
   devices directly at `/sdcard/btsnoop_hci.log`). Open in Wireshark.

Scenario A — FTMS baseline (any FTMS-gen pad):

1. Connect KS Fit to the pad; wait for property/model sync to finish.
2. Start the belt, set speed 2.0 → 4.0 → 6.0 km/h, pause, resume, stop.
3. Pull the log.

Answers:

- **Set-speed opcode on the owner's firmware** (gap 4 follow-up): filter
  ATT writes to the handle of 0x2AD9; confirm `02 <lo> <hi>` uint16-LE
  km/h×100. On an X21 (incline), also capture an incline change and confirm
  it is opcode `03` (Set Target Inclination) — this nails the 0x02-vs-0x03
  discrepancy shut.
- **ODM pre-amble**: confirm the 8-byte frame `01 00 0d 00 06 0b 0f 0d`
  precedes each Control Point write, and **record the full response** on the
  ODM characteristic (property table — enables decoding capabilities/model
  fields; note its length and repeating record structure).
- **0x2ADA "safe_off" opcode set** (gap 2): the stop/pause events above
  produce 0x2ADA notifications; expect FTMS-standard opcodes (0x02
  started/resumed, 0x03 stopped/paused + param, possibly 0x04 safety key).
  Correlate each opcode with what the app UI showed ("device status
  change"). If the pad has a safety key / magnetic kill switch, pull it once
  mid-walk — that capture is the key one for "safe_off".

Scenario B — supplement service (KS-HD-* pads only):

1. In KS Fit, exercise every supplement-surface feature: open device
  settings (property list), edit user profile, toggle units, open offline
  workout history, start and cancel an OTA check/download.
2. Pull the log.

Answers:

- **Per-characteristic roles of 24e2521c-…0b/0d/0e/0f** (gap 1): map each
  ATT write/notification handle to its UUID; confirm the hypothesis that
  0b/0d are the command/response pair and identify what 0e/0f carry
  (OTA data? long properties? unused?).
- Confirm frames use body + 1-byte additive checksum (wrapSupplementCmd).

Scenario C — WiLink legacy (only if the pad advertises 0xFE00; R1 especially):

1. With the WalkingPad app (v2.5.5 is WiLink-only), connect, query status,
  set several speeds incl. 0 (stop), switch modes, start the belt.
2. Pull the log.

Answers:

- **Frame construction/checksum on real hardware** (gap 5): verify writes to
  0xFE02 match `F7 A2 01 <speed> <crc> FD` with `crc = sum(bytes[1:-2]) &
  0xFF`, and notifications on 0xFE01 match the documented 19-byte F8 A2
  layout.
- **`_setSpeedR1` variant**: the v2.5.5 binary has a separate R1 speed
  builder; if the pad is an R1/R1 Pro, diff the emitted set-speed frames
  against the A1 grammar — any deviation is new spec material.
- Capture one F8 A7 workout-record response after a walk (record pops).

## 3. Linux-side validation (optional, no phone)

Drive the pad from a Linux box with `bluetoothctl`+`btmon` running, using
`mcdax/walkingpad-controller` (FTMS) or `ph4-walkingpad` (WiLink):

- `sudo btmon -w walkingpad-linux.snoop &` then run the controller's
  connect → set speed → stop sequence.
- Confirms the third-party stack reproduces the official app's on-wire
  behaviour byte-for-byte (incl. ODM pre-amble and tolerated
  REQUEST_CONTROL rejection), i.e. the spec is implementable as written.

## 4. Wireshark tips

- Filter writes: `btatt.opcode == 0x12 || btatt.opcode == 0x52` (write
  request / write command); notifications: `btatt.opcode == 0x1b`.
- Resolve handles→UUIDs from the "Read By Group Type Response" at connection
  start, or from the nRF Connect dump in section 1.
- FTMS Control Point is small; search bytes `02 ?? ??`, `07`, `08 01|02`
  near the connection's writes. ODM frames: search for the hex string
  `01 00 0d 00 06 0b 0f 0d`.

## 5. Safety

- This is a moving belt under a person: run speed changes **unloaded**
  (nobody on the pad) at ≤ 3 km/h where possible; keep the physical stop
  control in hand.
- Do NOT write calibration (`F7 A2 03 …`), max-speed preference
  (`F7 A6 03 …`), or any OTA characteristic during these captures — read-only
  features and normal app usage only.
- OTA: in scenario B, start the OTA *check* but cancel before flashing;
  interrupted flashes can brick the controller.

## 6. What to file back

For each capture: btsnoop file, phone model/Android version, app version,
pad advertised name + MAC + firmware string (DIS 0x2A26), and which scenario
letter it was. These feed spec updates with `verification` bumped to
"confirmed" (hardware) per command.
