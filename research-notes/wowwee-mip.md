# WowWee MiP / MiPosaur — Research Notes

## What it is
**WowWee MiP** (2014, TOTY 2015 Innovative Toy of the Year): two-wheeled self-balancing robot, BLE app control (Drive/Dance/Battle/Path/Stack modes). Same BLE protocol family covers **MiPosaur** (2015), **MiP Arcade**, **Turbo Dave / Minion MiP** (`com.wowwee.minionmip`), and **Roboraptor Blue** (BLE per WowWee product page). The older **Robosapien X** is NOT BLE (IR dongle) — exclude.

## Why it is abandoned / at-risk
- WowWee the company is **alive** (wowwee.com maintained, current products are Got2Glow/fidget lines), but the MiP product line is discontinued legacy hardware and the apps are unmaintained: MiP app final build **v3.0** (versionCode 31, ~2018-era), no updates since.
- App is no longer reliably on Google Play (mirror distribution: APKPure, Uptodown "MiP 3.0"). Support pages still up but the ecosystem is clearly in maintenance-mode decay.
- Robot works fine standalone (gesture/roam modes), so this is "app-orphaned hardware", not a brick — but all programmable modes need BLE.

## Local BLE feasibility: EXCELLENT
- WowWee **published official SDKs** pre-abandonment (github.com/WowWeeLabs): [MiP-Android-SDK](https://github.com/WowWeeLabs/MiP-Android-SDK), [MiP-Node.js-SDK](https://github.com/WowWeeLabs/MiP-Node.js-SDK), [MiP-Windows-SDK](https://github.com/WowWeeLabs/MiP-Windows-SDK) — these ship the protocol command tables.
- Community RE: [adamgreen/MiP](https://github.com/adamgreen/MiP) — full C API + protocol documentation from HCI snooping; [vlimit/mip](https://github.com/vlimit/mip) — original 2014 RE effort.
- GATT confirmed in `com.wowwee.mip` v3.0 DEX (shared `bluetoothrobotcontrollib`):
  - Service `0000ffe0-0000-1000-8000-00805f9b34fb`
  - Write commands: `0000ffe9-…`; Notify: `0000ffe4-…` (matches adamgreen's docs)
  - `0000ffe5-…`, `0000fff0-…` also present (OTA/secondary), plus a broad `ff00–ffb0` table from the shared WowWee robot lib (covers other robots; not all apply to MiP).
  - Standard DIS `180a`, battery `180f/2a19`, strings `MIP_`, `MIP_BLUETOOTH_PRODUCT_ID`, firmware-version strings.
- Command set (from official SDK headers): drive (time/distance-based), turn, continuous drive, chest LED RGB, head LEDs, gesture/radar mode, sounds, fall-over detection, shake, clap response — single-byte opcodes with small payloads on `ffe9`.

## APK provenance
- **Package**: `com.wowwee.mip` ("MiP"), version **3.0** (versionCode 31).
- **Source**: apkeep `-d apk-pure` (XAPK; base + locale/density splits).
- **SHA-256 (XAPK)**: `3113cc81aa75aea7dbd5e81a67142e10644ab7c6768af6b540c3e32f2272710a`
- APKPure has full history 1.8 → 3.0. Related: `com.wowwee.miposaur`, `com.wowwee.minionmip` (not fetched; same lib).

## What needs cloud
- Nothing. No account system in the app at all; pure local BLE.

## Open questions
- Which `ffxx` characteristics belong to MiPosaur/Turbo Dave vs MiP — the shared lib lumps them; one nRF Connect scan per robot would sort it.
- MiP firmware-update channel (there are `mip_firmware` strings + `ff90–ffa2` block — possibly OAD): worth one static pass only if OTA spec is in scope.

## Verdict
Document. Official SDKs + mature community protocol docs + confirmed GATT = spec consolidation task. Company alive but ecosystem abandoned; zero cloud dependency.
