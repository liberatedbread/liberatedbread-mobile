# Cobra Tag — Research Notes

## What This Is
Cobra Tag (Cobra Electronics, launched CES/Sept 2011, ~$30–60). Key-fob
two-way finder: phone app watches the BT link and alarms both ends on
separation (~30 ft); button on the fob rings the phone and vice versa.
Product long discontinued (Cobra pivoted back to radar/dashcams; Cobra
Electronics itself still exists under Cedar Electronics — so this is
"abandoned product", not "dead company").

## Transport
- **Bluetooth Classic 2.0, Class 2** (10 m) — per the official spec sheet
  (janserwis.pl mirror of cobra_tag.pdf). "Made for iPhone" badging implies
  MFi classic-BT accessory, not BLE (iPhone 4S-era; pre-BLE-accessory wave).
- Simultaneous connection to 2 phones claimed on spec sheet.
- Separation/link-loss detection needs no cloud — the app monitors the local
  link (CNET/Computerworld hands-ons, Sept 2011). No account mentioned in any
  contemporary review.

## App / APK status
- Android app existed ("Cobra Tag", distributed via Android Market 2011–2014
  era; mirrors like soft112 list version dated 11/27/2012).
- **APK NOT fetchable**: `com.cobra.tag` and `com.cobratag` both absent from
  apk-pure via apkeep (2026-08-03). True package id unconfirmed — those two
  were guesses. This raises difficulty: protocol must come from a surviving
  mirror APK or live capture.
- iOS app never shipped at launch (CNET: "an iPhone version of the Cobra Tag
  app is not available", 2011); Android + BlackBerry first.

## Feasibility
- **Hypothesis (moderate)**: As a classic-BT MFi-era fob it almost certainly
  uses SPP or HFP with a simple link-supervision scheme (like ZOMM). If the
  fob pairs at OS level, the two-way find-me function may be reachable with a
  generic RFCOMM client; the separation alarm works by definition without any
  app on the fob side (fob alarms on link loss).
- Blockers: no APK in hand; no community RE found (nothing on GitHub/forums
  beyond period reviews); hardware is scarce but cheap on eBay.

## Sources
- CNET hands-on (2011-09-07): https://www.cnet.com/roadshow/auto-tech/cobra-tag-finds-your-keys-finds-your-phone-hands-on/
- Computerworld (2011-09-09): https://www.computerworld.com/article/1494624/hands-on-cobra-tag-lets-you-find-lost-keys-with-your-phone.html
- Official spec sheet (BT 2.0 Class 2, Made for iPhone, 2 phones):
  https://janserwis.pl/wp-content/uploads/2024/03/cobra_tag.pdf
- soft112 app mirror listing: https://cobra-tag.soft112.com/

## Next Steps
1. Find the real package id (Wayback machine of the old Android Market page)
   and re-try apkeep / third-party mirrors.
2. If hardware is acquired: `sdptool browse` to enumerate SDP records, then
   RFCOMM connect + observe.
