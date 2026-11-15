# Bluesmart One / Series 2 — BLE Smart Luggage Research Notes

## What it is
Bluesmart One (2015, Indiegogo ~$2.2M) and Bluesmart Series 2 (2017) are
connected hard-shell suitcases with: motorized TSA smart lock (remote
lock/unlock from phone), built-in digital scale (lift the handle), GPS +
3G location tracking, 10,400 mAh battery bank (non-removable on One), and
BLE proximity alerts. All phone-facing control is BLE; GPS/3G reporting
and account/sync went through Bluesmart's cloud.

## Why it's abandoned (dated sources)
- 2018-01-15: major US airlines ban checked smart luggage with
  non-removable lithium batteries.
- 2018-05-01: Bluesmart winds down, sells all tech/designs/brands/IP to
  Travelpro; all warranties and returns voided. "The company's servers
  and apps will stay online for several months" — i.e. long dead by now.
  Source: https://techcrunch.com/2018/05/01/bluesmart-sells-assets-to-travelpro-following-smart-luggage-ban/
  and https://www.engadget.com/2018-05-01-bluesmart-smart-luggage-shutting-down.html
- Travelpro never revived the consumer app/cloud; the Bluesmart apps are
  gone from both stores (verified 2026-08-03: Play `com.bluesmart*` 404;
  Apple Search API returns no Bluesmart luggage app).

## Local BLE feasibility
- The lock, scale, battery status and proximity are BLE functions driven
  directly from the app (the case pairs to one phone). The Bluesmart
  manual (Amazon-hosted PDF, m.media-amazon.com/images/I/81YPR-H7GYS.pdf)
  confirms BLE pairing and a physical Travel Sentry key override — owners
  are never fully locked out, so RE attempts are low-risk.
- What needed cloud: account creation, GPS location reports, trip sync.
  Lock/unlock and weighing are plausible as pure local BLE.
- No known community RE (searched GitHub 2026-08-03: nothing for
  Bluesmart luggage; no Gadgetbridge/HA support). Greenfield target.

## APK details — NOT fetchable (verified 2026-08-03)
- Package id uncertain (`com.bluesmart`, `com.bluesmart.one`,
  `com.bluesmart.app` all 404 on Play; a Sailfish forum post from 2021
  shows the app was still installable from Play via Aurora Store then, so
  it was delisted sometime after 2021).
- apkeep (apk-pure source): no result for all candidate ids.
- APKPure direct slugs: 404. APKCombo: 404. Aptoide API search: nothing.
- Recovery path: `adb pull` from an owner handset that still has the app,
  or an old APK mirror upload. iOS app is equally gone.

## Safety class
LOW for BLE work — the lock has a physical TSA key override, so a failed
unlock command cannot brick access. The integrated battery is a fire
concern in general (reason for the airline ban) but not RE-relevant.

## Open questions
- BLE name prefix / service UUIDs — unknown; needs nRF Connect scan of a
  live unit (cases are plentiful on eBay).
- Does pairing require the dead cloud account (key exchange via server)
  or is the unlock credential stored on-device? Determines whether local
  resurrection is trivial or requires an enrolled-phone capture.
- Series 2 electronics differ (removable battery) — treat separately.

## Next steps
1. Acquire a Bluesmart One (used, cheap) + nRF Connect scan for UUIDs.
2. Source the APK (adb pull from an old phone; archive.org mirror hunt).
3. HCI snoop lock/unlock/weigh from a phone that still has the app.
