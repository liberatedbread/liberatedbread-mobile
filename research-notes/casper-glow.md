# Casper Glow Light — Research Notes

Portable gesture-controlled sleep/wake light (2019) by Casper. Flip to turn on,
rotate to dim, wobble to cancel; gradual sunrise wake-up. Category: sunrise/sleep light.

## Cloud status: NOT abandoned — included as a proven-local reference
- Casper still lists the Glow for sale (casper.com/products/glow, checked 2026-08) and
  the Glow app still works on current Android per user reviews (Pixel 6 / Android 14).
- Caveats that keep it at-risk-adjacent: Casper went through distress — taken private
  by Durational Capital in early 2022 after large losses ([Nasdaq Q4 2020 results](https://www.nasdaq.com/press-release/casper-reports-fourth-quarter-2020-results-2021-02-24))
  — and the Glow app has a history of connectivity bugs ([Casper help center](https://help.casper.com/s/article/My-glow-is-working-but-the-app-shows-it-as-being-not-connected-How-can-I-fix-this)).
- Treat as: vendor alive, product alive, app quality poor → the value here is that
  local BLE control is **already fully documented by the community**, making this the
  cheapest possible win in the category and a reference implementation.

## Local BLE feasibility — PROVEN
- **Home Assistant core integration** `casper_glow`: added in HA 2026.4 (silver),
  platinum quality by 2026.6 — [HA 2026.4 release notes](https://www.home-assistant.io/blog/2026/04/01/release-20264/),
  [integration docs](https://www.home-assistant.io/integrations/casper_glow/).
- Backing library: [mikeodr/pycasperglow](https://github.com/mikeodr/pycasperglow) —
  async Python (bleak) BLE control: brightness, on/off, battery sensors.
- The light works with zero app/account: gestures are on-device; BLE is optional.
  No cloud needed at any point.

## APK provenance
- Android app package id not confirmed; `com.casper.glow`, `com.casper.sleep`,
  `com.casper.glowapp` all absent from apk-pure (2026-08-03). Not needed given the
  community protocol, but an APK pull would confirm UUID parity.

## Protocol pointers
- All protocol facts live in pycasperglow (service/characteristic UUIDs, brightness
  encoding). Not re-derived here — cite the repo rather than duplicating.

## Open questions
- Gesture/Wake-up schedule programming over BLE (app feature) vs simple on/off/brightness
  in pycasperglow — is the schedule characteristic mapped?
- Actual Play Store package id for the record.

## Status
- apk_acquired: no (not needed; not found on apk-pure); protocol: fully RE'd by community.
- Safety class: LOW (dimmable lamp only).
