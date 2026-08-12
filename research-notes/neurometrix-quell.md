# NeuroMetrix Quell / Quell 2.0 — BLE Wearable TENS — Research Notes

Date researched: 2026-08-04.

## What it is
Quell is a calf-worn transcutaneous electrical nerve stimulation (TENS) device for
chronic pain, controlled over BLE from the "Quell Relief" smartphone app. The
hardware has a single button; therapy start/stop, intensity, calibration, and all
history readout go through the app. Quell 1.0 (2015) and Quell 2.0 (2018) are the
consumer lines; Quell Fibromyalgia (Rx, FDA-authorized 2022) is the current one.

## Why it is abandoned / at-risk
- NeuroMetrix support site states plainly: **"Quell Discontinued Quell 2.0
  Product"** — legacy consumer line is dead; electrode refills were the last
  supported consumable ([support.quellrelief.com](https://support.quellrelief.com/hc/en-us), viewed 2026-08-04).
- NeuroMetrix was acquired by electroCore, Inc. — deal completed **2025-05-05**
  ([Medical Device Network](https://www.medicaldevice-network.com/news/electrocore-neurometrix-acquisition/)).
  The Quell platform survives only as the prescription Quell Fibromyalgia sold via
  the VA channel; the consumer app/ecosystem future under electroCore is uncertain.
- Quell 1.0/2.0 units in the field are bricks-without-app: no display, no onboard
  program selection. If the app disappears from stores, local BLE is the only path.

## Local BLE feasibility: HIGH (confirmed)
- App drives therapy **entirely over local BLE**: start/stop therapy, intensity
  up/down, calibration, time sync, settings, history sync. Cloud account exists
  (`ui/account/CreateAccountFragment`, `quellwebservice/QuellWebService`) but is
  for backup/sync; no evidence device control routes through the cloud.
- All GATT service/characteristic UUIDs and the full app-control command set were
  recovered from the APK (see YAML). Advertised service UUID:
  `75000d1f-1000-40f7-8204-ee627068ec88`.
- Command channel: write a 32-bit value to appControl characteristic
  `75000d1f-4001-40f7-8204-ee627068ec88`. Values recovered verbatim, e.g.
  START_THERAPY `0x3801f66f`, STOP_THERAPY `0x9500ae5d`, INCREASE_INTENSITY
  `0x2003288d`, DECREASE_INTENSITY `0x98023e4e` (full table in YAML).
- No prior community RE found (no GitHub driver, no HA integration) — this repo's
  static pass appears to be the first public UUID/command map.

## APK Provenance
- **Package**: `com.neurometrix.quell` ("Quell Relief App")
- **Source**: apkeep, apk-pure; versions 2.0.0 … 3.1.6 listed; downloaded 3.1.6 (XAPK, versionCode 165, targetSdk 35 — still store-maintained as of acquisition)
- **XAPK SHA-256**: `4dc9b79c21db5afb7d08a3b106e1c4e9aeb78f6e1d71858d6ab96038a7f1d5f3`
- **Base APK SHA-256**: `833d840963fe8ce00809afd9a66a74178cd6beddae67842d78937600f16d59a7`
- **Framework**: Native Java/Kotlin, RxJava, Dagger; packages unobfuscated (`com.neurometrix.quell.bluetooth.*`)

## Protocol notes
- Clean layered BLE stack: `BluetoothCommon.java` defines the whole GATT table;
  per-characteristic `translators/` pack/unpack; `updateHandlers/` process notifies.
- Endianness of the 32-bit app-control word on the wire is TBD (`ByteUnpacker`
  bit-packing; verify against HCI snoop). Both byte orders are listed in the YAML.
- Device status characteristic (`…-1001`) carries battery, therapy elapsed,
  on-skin, stimulation intensity, device state (THERAPY etc.) — single notify
  gives a full state snapshot.
- OTA service (`…-6000`) is custom (control/data/checksums), not Nordic DFU.

## What needs cloud
Nothing for therapy control. Account only for cross-device sync/backup
(hypothesis from package structure — verify app launches offline).

## Open questions
1. Wire byte order for app-control command word (LE vs BE).
2. Pairing: does the device bond/encrypt? (ScanHelper/DeviceMatcher don't show
   auth requirements; likely just-works.)
3. Do Quell 1.0 firmware and the Rx Quell Fibromyalgia share this exact GATT table?
4. Electrode-supply business decision by electroCore — long-term consumable risk.

## Safety
safety_class MEDIUM: active electrical stimulation. Commands cap out at
intensity steps the firmware enforces; do not implement raw waveform control
beyond the app's virtual-button commands.
