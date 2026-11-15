# Pantelligent Smart Frying Pan — Research Notes

## What it is
Pantelligent (2015 Kickstarter, shipped 2016, ~$199): 12-inch non-stick frying
pan with a temperature sensor + Bluetooth LE in the handle. The app guides
recipes against the pan's live surface temperature (CNET review 2015-12-18).
Sensor-only device — no heating element — so it is a BLE read-out target.

## Why it's abandoned (dated sources)
- The Spoon (2019-09-30), covering competitor SmartyPans: "Pantelligent … first
  started shipping the product in 2016 but has since gone out of business."
  (https://thespoon.tech/bluetooth-connected-smartypans-has-started-shipping/)
- MIT Slice of MIT (2015-05-18) alumni article, comment thread: company shut
  down after a patent-infringement lawsuit.
  (https://alum.mit.edu/slice/pantelligent-cooking-just-got-lot-smarter)
- App gone from Google Play/App Store; website defunct.

## Local BLE feasibility
Plausible and simple in principle: the pan only needs to stream temperature over
BLE GATT (likely a single notify characteristic). No cloud was ever needed for
the reading itself — the app supplied recipes/guidance. No community RE found
(2026-08) — greenfield, but this is about the easiest RE class there is.

## APK
- Package id unknown — guesses (`com.pantelligent`, `com.pantelligent.app`,
  `com.pantelligent.pantelligent`, `com.pantelligent.cook`) all returned nothing
  from apkeep/apk-pure on 2026-08-03.
- iOS app name was "Pantelligent". An archived APK may exist on APKCombo-style
  mirrors; not verified. **Treat APK as unfetchable** → raises difficulty;
  fallback is brute-force GATT enumeration with a BLE scanner (device is
  read-only, low risk).

## Open questions
1. Advertising name / service UUIDs — needs one unit + `bluetoothctl` scan.
2. Temperature encoding (likely °C/°F int16; pan surface range up to ~260 °C).
3. Whether pairing/bonding is enforced.

## Safety
LOW — read-only temperature sensor, no actuation.
