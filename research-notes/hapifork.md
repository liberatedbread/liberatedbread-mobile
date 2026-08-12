# HAPIfork (Hapilabs) — Research Notes

## What it is
HAPIfork (Hapilabs, Paris; Kickstarter 2013, shipped Oct 2013, $99): the
"connected fork" that times bites ("fork servings"), vibrates + lights an LED
when you eat too fast, and syncs meal stats to a phone app over **Bluetooth 4.0
(BLE)** or micro-USB (Engadget hands-on 2013-04-17; EDN teardown notes ARM
Cortex-M0, 3.7 V LiPo, capacitive detection).

## Why it's abandoned
- Hapilabs effectively vanished after ~2015; website/social dead, no successor
  products. (Company history: Engadget/EDN coverage ends 2013-2015; founder
  Fabrice Boutain moved on.)
- soft112 listing: "this app was removed from Google Play"; no alternate APK
  mirrored there. (https://hapifork.soft112.com/hapifork-alternatives.html)
- Note: the fork's core haptic feedback is **autonomous** — it vibrates without
  any app. BLE only syncs statistics to the (dead) cloud dashboard/app.

## Local BLE feasibility
Marginal. Reading meal stats over BLE should be trivial GATT work, but the
value is low (stats only — the behavior feedback never needed the app) and
there is zero prior art. Include only if a unit is cheap/available.

## APK
- Package id unknown; apkeep/apk-pure misses for all guesses
  (`com.hapilabs.hapifork`, `com.hapifork`, `com.hapilabs.hapi`,
  `com.hapilabs.hapiforkapp`) on 2026-08-03. App removed from Play.
- **Treat APK as unfetchable** → direct GATT probing would be required.

## Open questions
1. Does the fork even run a connectable GATT server, or only pair on demand?
2. Stat upload format (also possible via USB mass-storage/serial — the USB path
   may be easier than BLE).

## Safety
LOW (utensil; health-coaching claims only).
