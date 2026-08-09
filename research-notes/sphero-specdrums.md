# Sphero Specdrums — Research Notes

## What it is
Silicone finger rings with a color sensor + accelerometer: tap a colored
surface and the companion app plays a mapped sound. 1/2-ring consumer packs and
a 12-ring EDU pack (model SD01WR). Bluetooth 4.0 (BLE). Acquired by Sphero 2018
from the original Kickstarter startup.

## Why it's abandoned
- **Specdrums MIX app removed from the App Store AND Google Play in August
  2024; Specdrums Edu app also removed**
  ([Sphero support](https://help.sphero.com/sphero-support/specdrums-edu-and-mix-apps)).
- Support pages now banner "Sphero Support Discontinued" for Specdrums.
- Sphero itself is alive (education robots) but has fully orphaned this
  product: no app, no firmware path, no support.

## Local BLE feasibility: GOOD, two layers
1. **Standard BLE MIDI**: Sphero's own marketing states the rings "connect to
   any other music software that accepts Bluetooth MIDI, such as GarageBand
   and Ableton Live" — i.e. the ring can act as a plain BLE-MIDI controller
   (color tap -> note) with no Sphero app. This alone keeps the hardware
   useful. (Confirm which ring firmware/mode exposes BLE-MIDI; likely set from
   the app — see open questions.)
2. **Native app protocol**: MIX/Edu apps talk to the ring over a custom GATT
   profile for raw color/tap events, LED control, battery, and MIDI-mode
   config. Decompiling `com.sphero.specdrumsmix` (jadx, triage pass) shows the
   app uses Sphero's generic BLE convenience stack
   (`com.sphero.platform.BtLe`) which **discovers service/characteristic UUIDs
   at runtime** — no hardcoded ring UUIDs were recoverable in a cheap static
   pass. Getting the custom profile needs either deeper jadx time on the
   `com.sphero.jams` module or a quick nRF Connect / HCI-snoop session with a
   real ring (trivial: single peripheral, few characteristics).
- No prior public RE of the ring protocol found (Sphero robot RE — e.g.
  astagi/freer2 — exists but covers different hardware/API).

## What needs cloud
- Nothing for core play — sounds were bundled/downloaded in-app. Risk is the
  delisted apps themselves (APK archived below) and whether BLE-MIDI mode
  persists without the app.

## APK
- **Package**: `com.sphero.specdrumsmix` (Specdrums MIX) — fetched via apkeep
  (apk-pure), v1.2.2 (final), bare APK 100 MB,
  sha256 `0f242655139bf0d0b8ea204e38df55c5edd08f0de3265d034ffe68a77ed4d822`.
- jadx triage done (partial decompile, exit 1 but sources produced) at
  `workspace/static/specdrums/`; findings above.
- Specdrums Edu app package id not investigated (iOS-focused; MIX covers the
  protocol).

## Open questions
- Exact GATT service/characteristic UUIDs + tap/color/LED frame format — one
  nRF Connect session resolves this.
- How is BLE-MIDI mode enabled, and does it persist across power cycles without
  the app?
- Does the MIX 1.2.2 APK still function offline on modern Android (it predates
  scoped-storage/permission changes)?

## Safety
None — toy ring, LED + vibration only.
