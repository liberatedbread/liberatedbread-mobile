# Sensel Morph — Research Notes

## What it is
Pressure-sensitive multi-touch controller (~20k sensors) with magnetic swappable
overlays (piano, drum pad, Buchla Thunder, QWERTY, gamepad...). USB plus
**Bluetooth LE (standard BLE MIDI)**; MPE-capable. Configured via the desktop
SenselApp (Windows/macOS/Linux) which flashes maps to the device — after
mapping, the Morph runs standalone.

## Why it's abandoned
- Sensel discontinued the Morph and all accessories **2022-05-05** ("no longer
  producing the current Morph... discontinuing all hardware production runs
  indefinitely") and pivoted to laptop touchpad OEM business
  ([Synthtopia, 2022-05-06](https://www.synthtopia.com/content/2022/05/06/sensel-discontinues-morph-controller-focuses-on-laptop-touchpad-market/),
  [user announcement](https://community.polyexpression.com/t/end-of-sensel-morph/1195)).
- Sensel Inc. still exists (touchpads) but the Morph product line, app, and
  store are orphaned. Official docs survive at
  [sensel.github.io/morph-docs](https://sensel.github.io/morph-docs/morph/).

## Local BLE feasibility: GOOD (confirmed)
- Overlays configured for MIDI emit **standard BLE MIDI** — any BLE-MIDI host
  can play it with zero Sensel software.
- Mapping/configuration: SenselApp talks to the device over USB serial; the
  protocol is open — Sensel published the official
  [sensel-api](https://github.com/sensel/sensel-api) (C/C#/Java) for raw
  contact frames, and the map format is documented in morph-docs.
- Community: sensel/morph-docs on GitHub; various Max/PD and Python
  integrations. No cloud account was ever required for any function.
- BLE carries MIDI only; raw high-resolution contact data and map upload go
  over USB. So BLE local control = play + whatever MIDI maps are flashed.

## What needs cloud / app
- Nothing needs cloud. Risk is bit-rot of SenselApp downloads (still hosted on
  sensel.com as of 2022+; archive installers + firmware) and no future firmware.
- No Android APK exists — SenselApp was desktop-only, so the apkeep step is N/A.

## APK
- None (desktop-only companion). apk_acquired: false (not applicable).

## Open questions
- Can map upload / config be done over BLE at all, or strictly USB? (Believed
  USB-only for maps — confirm from sensel-api.)
- Long-term host for SenselApp installers and Morph firmware images.
- Is the BLE-MIDI implementation MPE-complete (per-channel pitch bend) on all
  overlays?

## Safety
None — controller only.
