# Xmetrics Swim Tracker — Research Notes

## What It Is
Clip-on swim sensor (worn at the back of the head/on goggle strap) from Xmetrics SRL
(Milan, Italy). Indiegogo October–December 2014; shipped as Xmetrics and later
Xmetrics Pro (~2016–2017). Accelerometer-based stroke/lap/efficiency metrics with
real-time audio feedback to the swimmer, Bluetooth sync to iOS/Android app.
- [SwimSwam, 2014-10-18](https://swimswam.com/xmetrics-the-worlds-first-activity-tracker-for-swimmers/)
- [Daily Burn, 2014-12-05](https://dailyburn.com/life/tech/xmetrics-swimming-workouts-tracker/)
- [Wareable "best wearables for real time coaching" (XMetrics Pro review), 2017-03-10](https://www.wareable.com/fitness-trackers/best-wearables-for-coaching-2056)

## Why It's Dead
- Product listed as discontinued ([360swim blog](https://360swim.com/blog/swimming-wearable-xmetrics)).
- The Android app is gone from Google Play (Play search returns nothing, verified
  2026-08-07); no APK mirror hit for guessed package ids.
- xmetrics.it intermittently fails (HTTP 520 on 2026-08-04) and is a frozen WordPress
  site: homepage last modified **2020-03-03**, zero posts (wp-json, verified
  2026-08-07). Effectively a zombie site.
- Crunchbase still lists Xmetrics SRL as "Active" — stale data; no product, no app,
  no site updates for ~6 years.

## Local BLE Feasibility — PLAUSIBLE, UNVERIFIED
- Per launch coverage the tracker syncs to the phone app over Bluetooth (BLE-class,
  BT 4.0 era hardware). Real-time audio feedback is generated on-device, so the core
  training function never needed a phone in the water.
- Whether workout sync requires a cloud account is unknown — the app is unavailable,
  so this is the key open question. No community RE, no Home Assistant/Gadgetbridge
  support found.
- Local-only control is plausible (typical GATT workout-pull design) but currently a
  hypothesis.

## APK Provenance
- App: "Xmetrics" (iOS/Android), package id UNKNOWN
- Tried and failed via apkeep (apk-pure): `it.xmetrics`, `it.xmetrics.app`,
  `com.xmetrics`, `com.xmetrics.swim`, `it.xmetrics.swim`, `com.xmetrics.xmetrics`
- No Play/Wayback store link found on archived xmetrics.it pages
- **APK not acquired** — this is what makes the device HIGH difficulty. A hardware
  unit + nRF Connect enumeration, or an IPA/APK from an old device, would unblock it.

## What Needs Cloud
Unknown. Assume account-based history sync like its peers; real-time audio feedback
and on-device operation are cloud-free by design.

## Open Questions
- Exact package id / any surviving APK or IPA.
- BLE transport details (service UUIDs, sync protocol) — needs hardware or binary.
- Did the app work without account registration?
- Any remaining user community (masters-swimming forums) with working units?
