# i'm Watch — Research Notes

The 2011 Italian "first real smartwatch": a full Android 2.x computer on the
wrist that tethers to a phone over Bluetooth Classic. Company long dead;
partial local usefulness remains via standard BT profiles.

## Device / Company Status
- **Product**: i'm Watch (i'm S.p.A., Italy; launched 2011-2012, ~€300):
  1.54" 240x240 colour touchscreen, speaker + mic, 3.5mm-era audio features,
  runs its own Android build with on-watch apps (i'market store).
  ([CNET review](https://www.cnet.com/reviews/i-m-watch-review/),
  [Gadgeteer review](https://the-gadgeteer.com/2013/01/11/im-watch-review-2/))
- **Company defunct**: no dated obituary found, but the evidence is unambiguous:
  imwatch.com is now a parked "lander" page (verified 2026-08-07), the i'market
  on-watch app store is dead, and the company's only GitHub presence
  (github.com/imspa) has been silent since 2013-06-04. Rated hypothesis on the
  exact wind-down date (~2015-2017).

## Local Feasibility: PARTIAL
- **What still works locally**: the watch is a standard Bluetooth handsfree —
  pairing with any phone gives calls/audio (HFP/A2DP) with zero vendor software
  and no cloud. On-watch apps that don't need network still run.
- **What is dead**: the smart tethering layer (notifications, email, weather,
  Facebook/Twitter) depended on the companion phone app plus i'm's cloud and
  i'market — all gone. No community re-implementation exists.
- **Toehold for RE**: i'm S.p.A. itself published watch-side Bluetooth APIs —
  github.com/imspa/imWatch-Bluetooth ("The Bluetooth APIs for the i'm Watch",
  2013). Combined with the fact that the watch is plain Android 2.x (adb,
  rootable community history), a local SPP notification bridge is feasible but
  is greenfield work.
- **No APK**: no required Android companion package could be identified on
  mirrors (the phone-side app shipped mainly for iOS; Android-side the watch
  did the heavy lifting). Nothing to fetch; static analysis would have to start
  from watch firmware dumps, not an APK.

## Open Questions
- Phone-side app package id (iOS-first; Android "i'm Watch" app existence and
  package unverified — not on APKPure under obvious names).
- SPP channel/UUID used by the watch's tethering service (would come from the
  imspa/imWatch-Bluetooth API docs or a firmware dump).
- Root/custom-ROM state of the watch community (XDA-era threads) — the Android
  base makes full local control plausible if anyone still owns one.

## Sources
- github.com/imspa/imWatch-Bluetooth (official Bluetooth APIs, last push 2013-06)
- cnet.com/reviews/i-m-watch-review/ (2013)
- the-gadgeteer.com/2013/01/11/im-watch-review-2/
- imwatch.com parked domain (verified 2026-08-07)

## Verdict
Include as a *partial* note: handsfree audio works locally forever; the smart
layer is dead and unrescued. Lower priority than Pebble/LiveView/MetaWatch/
Martian, where full local stacks exist.
