# Athos EMG Smart Apparel — Research Notes

## What It Is
Athos (Mad Apparel Inc., founded 2012, Redwood City) made compression shirts and
shorts with woven-in surface-EMG sensors: ~16 sEMG channels + heart rate and
breathing sensors in the shirt, 8 EMG + HR in the shorts. A snap-in "Core" module
digitizes everything and streams to the phone over Bluetooth. Kit MSRP ~$100–400.
Sources: [MobiHealthNews (2015-11)](https://www.mobihealthnews.com/news/athos-raises-355m-health-sensing-clothing-athletes),
[Apparel Resources (2020-02)](https://apparelresources.com/technology-news/manufacturing-tech/smart-athleisure-smarter-workouts/).

## Why It Is Abandoned
- **PitchBook company profile (accessed 2026-08-04): status "Out of Business"**:
  <https://pitchbook.com/profiles/company/56534-95>
- After a 2017 rebrand the company narrowed to elite-team sales
  ([Sports Business Journal, 2017-04](https://www.sportsbusinessjournal.com/Daily/Issues/2017/04/28/Technology/athos-rebrands-as-wearable-fitness-technology-company-focused-on-elite-athletes/));
  consumer gear and app quietly died afterward. An Alibaba product-insight article
  claims cloud services ended Q2 2022 — plausible but low-quality source, treat as
  unverified.
- liveathos.com is effectively gone (only a parked pre-order page remains archived).
- The iOS app no longer appears in App Store search (verified 2026-08-04 via
  iTunes Search API: no Athos Inc. result).

## Local BLE Feasibility
- The data path was **local by design**: garment sensors → Core → BLE → phone app
  with real-time "Live View" muscle maps. Cloud was only for sync/history/social.
  A dead cloud does not block raw streaming IF a working client exists.
- **The catch: there is no obtainable client.** The app was **iOS-only for its
  entire life** — "only works with iOS" per
  [Digital Trends (2022-04)](https://www.digitaltrends.com/home/best-smart-home-fitness-tech/)
  and [Reviewed.com](https://www.reviewed.com/laundry/features/would-you-pay-400-for-a-wearable-personal-trainer);
  an Android version was "planned" as early as 2015
  ([HowStuffWorks, 2015-05](https://electronics.howstuffworks.com/gadgets/fitness/athos-clothing.htm))
  but no evidence it ever shipped, and no APK exists on any mirror.
- The iOS app is now delisted, so even the IPA is only recoverable from owner
  devices/backups. No community RE of any kind found (GitHub, 2026-08-04).

## App / Binary Status
- **Android APK: never existed** (best current evidence). apkeep probes of guessed
  ids (`com.athosworks.athos`, `com.liveathos.athos`, `com.athos.app`, …) all fail.
- iOS IPA: delisted; bundle id unknown (did not survive in search indexes).
- Rescue path therefore = **greenfield protocol RE from hardware**: power a Core,
  nRF Connect scan, map GATT, characterize the EMG stream. EMG at ~200 Hz × 16
  channels (per secondary sources) is a lot of notify throughput — expect a custom
  streaming service, possibly with per-garment pairing in the Core.

## BLE Details
- Transport: BLE (multiple reviews: "sensors use Bluetooth to wirelessly transmit
  to the Athos mobile app"). One 2015 source calls the Core "a wi-fi type device"
  — almost certainly a journalist's error for "wireless"; no Wi-Fi hardware was
  ever documented.
- Advertising name / UUIDs: UNKNOWN. No public capture exists.

## Open Questions
- Did an enterprise/team Android or desktop client ever exist for the post-2017
  elite-athlete pivot? (Would change binary availability.)
- Is the Core firmware Nordic-based (DFU recoverable) or fully custom?
- Can the Core stream without an app handshake (always-on notify) or does it need
  an auth/calibration exchange first? Determines whether RE is easy or brutal.

## Verdict
**Dead-app-only, hypothesis-grade.** Transport is genuinely local BLE and the
hardware is the most capable in the category (16-ch sEMG), but with no obtainable
app binary and zero prior RE, this is a from-scratch reverse-engineering project
requiring hardware in hand. Rate HARD.
