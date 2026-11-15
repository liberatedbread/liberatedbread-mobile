# OBDLink MX+ — Hardware Capture Plan

Status of knowledge going in: the radio-side picture is recovered from static
analysis of the OBDLink Android app (7.4.0) and vendor docs; **nothing is
confirmed against hardware**. Every capture below upgrades a `reported` fact to
`confirmed` or kills it.

Spec under test: `device-specs/devices/obdlink-mx-plus.yaml`
Generic background: `device-specs/devices/obd2-bluetooth-adapter.yaml`

## APK provenance (basis of all static-analysis claims)

- Package: `OCTech.Mobile.Applications.OBDLink` ("OBDLink"), version **7.4.0**
  (versionCode 115, minSdk 24 / targetSdk 36), fetched 2026-08-08 with
  `apkeep -d apk-pure`.
- Files (in `workspace/apks/`, gitignored):
  - `OCTech.Mobile.Applications.OBDLink.xapk` — sha256
    `85126a3bb2aaec74fb79c7bbfaff0e3e45a2cb104d8c833d9b8593327f41d751`
  - base `OCTech.Mobile.Applications.OBDLink.apk` (extracted) — sha256
    `d4ffafcfcfa362079c792070c2a9cdb13631c6dcc1b8677805dba72068aded95`
- App is .NET MAUI; managed logic lives in AOT images plus a compressed
  `libassembly-store.so` (XABA store, XALZ/LZ4-wrapped DLLs). jadx output in
  `workspace/static/obdlink/` (Java shim layer only); the findings cited in the
  spec come from the recovered `OCTech.OBD2.dll` / `OCTech.OBDLink.dll` /
  `OBDLink.dll` metadata and string heaps (class/method names, user-string
  literals), not from the Java layer.

## Safety rules

- **Read-only first.** Session 1 sends nothing with `writes: true` and nothing
  that isn't `verification: confirmed` in a spec. AT/ST adapter commands and
  legislated reads (mode 01/03/09) are the whole menu.
- No service 04 (clear DTCs), no UDS writes, no enhanced/manufacturer functions
  until explicitly planned against a vehicle the owner can afford to have a
  warning light on.
- Adapter-side config commands from the STSL* family change sleep/wake
  behaviour — note current values with the read forms before writing anything,
  restore afterwards.
- Pin 16 is unswitched. The MX+ claims < 2 mA BatterySaver sleep; verify the
  sleep actually happens (current meter if available) before leaving it in.
- Firmware update is the one destructive operation on the adapter itself. Do it
  last, on mains power for the phone, with the recovery procedure printed out
  (power cycle → select device from list → retry, per vendor article
  43000705180).

## Setup

- MX+ on the owner's vehicle (or bench OBD breakout with 12 V on pins 4/5/16).
- Android phone with Developer options → **Enable Bluetooth HCI snoop log**
  (captures both Classic and BLE to btsnoop_hci.log).
- Second BLE client for independent probing (nRF Connect, or
  `scripts/obd_discover.py` / bleak script).
- Pull logs: `adb pull /sdcard/Android/data/btsnoop_hci.log` (path varies; use
  `adb bugreport` if needed).

## Session 1 — Radio surface (no vehicle traffic)

1. **Advertising dump.** With adapter powered, before pairing: record BLE
   advertising (local name, service UUIDs, manufacturer data, whether it
   advertises at all before the button is pressed). Question answered: does the
   BLE side advertise cold, or only in/after the pairing window?
2. **Pairing flow capture.** HCI-snoop the full vendor-app pairing: press
   Connect button → pair in OS settings → app connects. Record: which link
   comes up first (Classic L2CAP/SPP vs BLE), whether the button press is
   strictly required, window duration, whether encryption/bonding is negotiated
   on BLE too, and what the Auto vs Manual pairing mode changes
   (`OBDLinkMXPPairingMode`).
3. **GATT discovery dump.** Connect over BLE (nRF Connect): full service list.
   Confirm `FFF0/FFF1/FFF2`, CCCD 0x2902, any Device Information / Battery /
   vendor services beyond the serial pipe. This directly verifies the
   `services` block of the spec.
4. **Classic channel.** Note RFCOMM channel and whether SPP is open without
   prior pairing (should not be).

## Session 2 — Command round-trips (read-only)

Over each link in turn (BLE, then Classic), with HCI snoop running:

1. `ATZ` → banner; `ATI` → ID string; `ATRV` → voltage.
2. `STI` → STN chip ID + firmware version (expected: STN2255/2256 + 5.x).
   Also try `STIM`, `STMFR` (seen in app strings; meaning unverified).
3. Ignition on: `ATSP0` (auto) then `01 00` and `09 02` — confirm legislated
   reads and multi-frame reassembly work over BLE exactly as over Classic.
4. Compare timing: MX+ advertises ~4× speed vs generic adapters; note
   request→prompt latency on both links.
5. Vendor-app session: HCI-snoop the OBDLink app connecting and running a
   normal diagnostic scan. Extract the connect-time adapter config sequence
   (the exact AT/ST init string it sends) — that sequence is the reference
   client init for the spec.

## Session 3 — Firmware mechanism (observe, then optionally update)

1. In the app, open Firmware Updates → check what it reports as current vs
   available. Note the `api.obdlink.com` traffic (HTTPS — observe endpoints
   only, e.g. via app strings; do not MITM).
2. If an update is offered: HCI-snoop the entire update. Identify: which link
   it uses (Classic suspected — `DualModeRequiresClassicBluetoothException`
   hints some operations demand Classic), the bootloader entry command, chunk
   size (`OBDLinkFirmwareLoader.DefaultChunkSize`), and the validation pass.
3. Do **not** interrupt the upload. If it fails, follow the vendor recovery
   path and capture that too.

## Open questions to close

- Does the MX+ BLE pipe carry the full ST command set, or a subset (is firmware
  update Classic-only)?
- Is BLE pairing/bonding enforced on the MX+ (CX bonds with PIN 123456; MX+
  model unknown)?
- Auto vs Manual pairing mode: what actually changes on-air?
- Are firmware images signed, or only header/checksum-validated?
  (`InvalidFirmwareImageException` is client-side; an observed update plus the
  downloaded file answers this — the file is fetched from
  `api.obdlink.com/devices/...` and may be saved to app storage.)
- Does the adapter accept a second BLE connection while Classic is active?

## Evidence to file

- btsnoop logs per session (name: `mxplus-s1-radio.pcapng` etc., under
  `workspace/captures/` — check repo convention for capture storage before
  committing anything).
- GATT discovery dump (nRF Connect export or bleak script output).
- Transcript of Session 2 command round-trips (text).
- Update each `verification: "reported"` in the spec to `confirmed` with the
  capture reference, or correct the fact.
