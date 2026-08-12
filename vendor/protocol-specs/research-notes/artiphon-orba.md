# Artiphon Orba (1/2/3) + Chorda — Research Notes

## What it is
Handheld synth/looper/MPE MIDI controller (palm-sized, 8 capacitive pads +
accelerometer/gyro, built-in speaker). Orba 1 (Kickstarter Nov 2019), Orba 2
(2022, sample engine), Orba 3 (Oct 2024), plus Chorda (2023) and the older
INSTRUMENT 1. Talks MIDI over USB-C **and** standard BLE MIDI; works with any
BLE-MIDI host with no vendor software.

## Why it's abandoned
- Artiphon suspended operations Aug 2025 — "forced to suspend operations"
  ([polyexpression.com, 2025-08-19](https://community.polyexpression.com/t/artiphon-out-of-business/2347)).
- Chapter 7 (liquidation, not restructuring) bankruptcy reported
  ([Zynthian discourse, 2025-10-24](https://discourse.zynthian.org/t/artiphon-chorda-orba-instrument-1-and-bankruptcy/12524));
  subreddits r/Artiphon, r/orba, r/chorda track fallout.
- orba-protocol README (2026-06): "Artiphon, Inc. ceased operations and entered
  liquidation in 2025; the official Orba app and cloud are abandoned."
- Company is DEAD, not just at-risk. Companion apps (Orba app, Artiphon Connect)
  will not be maintained; preset/sample content was partly cloud-served.

## Local BLE feasibility: EXCELLENT (confirmed)
- Device is a standard **BLE MIDI** peripheral (service
  `03b80e5a-ede8-4b33-a751-6ce34ec4c700`, char
  `7772e5db-3868-4112-a1a9-f2669d106bf3`). MIDI/MPE in+out works with zero
  vendor involvement (macOS/iOS/Android/Windows 11 BLE-MIDI stacks, or any
  BLE-MIDI client library).
- Device configuration (presets, tunings, tempo, FX, LED/haptics) runs as
  **SysEx over the same MIDI stream** — identical payload over USB-MIDI and
  BLE-MIDI, only framing differs.
- **Protocol fully reverse-engineered** (verified byte-identical against BLE
  captures): [holofermes/orba-protocol](https://github.com/holofermes/orba-protocol)
  (spec + Python/JS reference libs, MIT/CC-BY; derived from the official
  Android app, published 2026-06). Companion single-file web app "Orba Console"
  drives the device over Web Bluetooth with no install or account.
- Prior community work: subskybox/Orba (preset/voicing tools, Orba 1),
  IanHalbwachs/orba-presets, Batninja/Orba-Preset-Editor.
- Caution from the RE spec: do NOT blind-scan SysEx register addresses —
  invalid reads can fault firmware and reboot the device.

## What needs cloud / app
- Firmware updates were delivered via the desktop app (Orba 1) — now orphaned;
  no public firmware archive known.
- "Stem Songs"/artist sound packs were downloaded content — gone with the cloud.
- Core play, looping, sampling (Orba 2/3 sample capture happens on-device),
  and all configuration are fully local.

## APK
- **Package**: `com.artiphon.orba` ("Orba (1) by Artiphon") — fetched via apkeep
  (apk-pure), latest listed 0.15.36, XAPK 85 MB,
  sha256 `78bd3b77b697ff446d047f3dda80ae7be96adeb3537cabaf91e3858e7ac2e670`.
  Stored in `workspace/apks/` (gitignored), base APK extracted at
  `workspace/static/orba-xapk/com.artiphon.orba.apk`.
- "Artiphon Connect" (Orba 2/3 + Chorda companion) package id not located on
  apk-pure (guesses com.artiphon.connect/orba2/chorda all failed); iOS version
  1.0.670 known. Would need Play API or adb pull from an owner device.
- Not decompiled here — unnecessary: holofermes/orba-protocol already did the
  full RE from this APK and published the spec.

## Open questions
- Does the same SysEx register map cover Orba 2/3 and Chorda, or Orba 1 only?
  (holofermes spec verified against a live Orba 1; community threads suggest
  Orba 2 differences.)
- Firmware image availability for archival (desktop app pulled updates from
  Artiphon servers).
- Chorda BLE config protocol is separate and un-RE'd as far as known.

## Safety
None — musical instrument, no actuators beyond speaker/haptics/LEDs.
