# ROLI Blocks / Seaboard RISE / LUMI-Piano M — Research Notes

## What it is
ROLI's MPE controller lines: Lightpad Block / Seaboard Block / Live-Loop-Touch
Blocks (magnetically snap-together control surfaces, BLE), Seaboard RISE
(25/49, BLE), and the post-2021 Luminary line: LUMI Keys / Piano M (BLE) and
Seaboard 2. All speak standard **BLE MIDI** for playing data.

## Why it's at-risk — happening right now
- ROLI Ltd filed for administration Sept 2021; assets moved to new entity
  Luminary (later Luminary ROLI Ltd, Companies House #13407346)
  ([MusicTech, 2021-09-02](https://musictech.com/news/industry/roli-bankruptcy-luminary-reboot-lumi/)).
- **Second collapse in progress**: The Times (2026-07-10) reports TriplePoint
  filed notice of intention to appoint administrators early July 2026; founder
  Roland Lamb's CEO termination registered April 2026; roli.com showed a
  maintenance page with ALL products (incl. software) out of stock, and
  customers report unfulfilled orders
  ([Synth Anatomy, 2026-08-01](https://synthanatomy.com/2026/07/roli-is-facing-serious-financial-difficulties-for-the-second-time.html)).
- The Blocks line was already discontinued; current ROLI sells only Seaboard /
  Piano M / Airwave. Blocks owners depend on legacy software that is one
  insolvency away from vanishing.

## Local BLE feasibility: GOOD (confirmed for playing; config is the gap)
- Playing: standard BLE MIDI — works with any BLE-MIDI host, no ROLI account.
- Config/control: the Block-side protocol (topology, LED framebuffer, touch
  gestures, config messages) is **publicly documented in source form** as the
  `juce_blocks_basics` module of JUCE (ROLI open-sourced it; now at
  github.com/juce-framework/JUCE `modules/juce_blocks_basics`). It implements
  the whole Blocks BLE stack: device discovery, topology packets, LED program
  upload (Littlefoot), touch streaming. Any host can drive a Lightpad Block's
  LEDs and read touches with no ROLI software.
- Littlefoot VM: Blocks run downloadable "Littlefoot" programs; ROLI Dashboard
  is the usual IDE but the bytecode format is documented in the JUCE module.

## What needs cloud (the actual risk)
- **ROLI Connect** (desktop hub) requires a ROLI account sign-in and downloads
  ROLI Dashboard + firmware images from ROLI servers
  ([support.roli.com firmware guide](https://support.roli.com/support/solutions/articles/36000513200-updating-your-piano-m-s-firmware)).
  If the company folds, firmware updates and fresh Dashboard installs die.
- Mitigation: ROLI posted standalone `.syx` firmware files for Blocks on
  support pages (e.g. "BLOCKS control 1.1.0.syx") — archivable NOW. Dashboard
  installers should be archived too.
- Day-to-day playing and even LED/touch control never touch the cloud.

## APK
- No Android config app ever existed for Blocks (NOISE was iOS-only).
- Adjacent: `com.roli.lumi` ("ROLI Learn", Piano M/Airwave companion) fetched
  via apkeep (apk-pure), XAPK 246 MB,
  sha256 `c787d883ba1c64d9296bcc45056ea64842894b028869344b23727713b7fc25f4`.
  Useful if Piano M BLE onboarding/protocol needs RE later. Not decompiled
  (triage budget; Blocks protocol already public via JUCE).

## Open questions
- Archive status of ROLI Dashboard installers and Blocks `.syx` firmware files
  (grab before any shutdown).
- Seaboard RISE BLE config (5D touch curves) — Dashboard-only; is the config
  SysEx documented anywhere besides JUCE/equator presets?
- Piano M / Airwave onboarding: does the Learn app need ROLI cloud sign-in
  before BLE works locally? (Support docs suggest app works after pairing;
  unverified.)

## Safety
None — MIDI controllers only.
