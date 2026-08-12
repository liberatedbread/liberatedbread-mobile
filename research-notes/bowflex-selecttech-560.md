# BowFlex SelectTech 560 Smart Dumbbells — Research Notes

## What it is
Adjustable dumbbell pair (5–60 lb per dumbbell, 16 settings) with a built-in "3DT"
motion/position sensor per dumbbell and an LCD on the handle. BLE link to the
"BowFlex SelectTech" companion app for rep/set counting, weight tracking, and
coaching videos. Launched ~2015 (Nautilus-era), developed for Nautilus by Veux Labs
(Android package `com.veuxlabs.titan.android`, codename "Titan").

## Why it's abandoned / at-risk
- Product page now marked **Discontinued** (bowflex.ca, accessed 2026-08-07:
  https://www.bowflex.ca/en-ca/product/560/100581.html).
- BowFlex Inc (ex-Nautilus) filed **Chapter 11 on 2024-03-04**; assets sold to
  Johnson Health Tech for $37.5M (BarBend 2024-03-06:
  https://barbend.com/bowflex-files-for-chapter-11-bankruptcy/ ; Tom's Guide
  2024-07-18: https://www.tomsguide.com/wellness/fitness/bowflex-has-filed-for-bankruptcy-should-you-still-buy-its-home-workout-equipment).
- The SelectTech app (`com.veuxlabs.titan.android`) returns **404 on Google Play**
  (verified 2026-08-07). New owner maintains JRNY, not this legacy app.
- Note: the 2025 CPSC recall (3.8M units) covers 552/1090, **not** the 560.

## Local BLE feasibility — STRONG
- Dumbbells are fully usable standalone (on-handle LCD shows reps/weight); the app
  is logging/coaching only. No account wall observed for core BLE use.
- Static analysis of app v2.1.1 recovered the **complete named GATT table**:
  - Service `TITAN_SERVICE` = `47b4f720-b4b1-11e3-821e-0002a5d5c51b`
  - Characteristics (base `...-0002a5d5c51b` unless noted):
    `4681cb20-b4ad-11e3-af3b-` TITAN_APP_COMMAND,
    `a5f644a0-b863-11e3-ac47-` TITAN_BATTERY_LEVEL,
    `41447ab0-063a-11e5-a6c0-1697f925ec7b` TITAN_CHALLENGE_KEY (different base),
    `710977a0-b4ab-11e3-8a05-` TITAN_COUNTDOWN,
    `84800c20-b4a3-11e3-980b-` TITAN_EVENT,
    `0a63cec0-b4aa-11e3-8f5c-` TITAN_IDLE_TIMEOUT,
    `032b9de0-f591-11e3-97fd-` TITAN_PLAY_SOUND,
    `a80dea40-b4a3-11e3-87e0-` TITAN_POSITION,
    `96aaed20-b4a3-11e3-b47d-` TITAN_REP_COUNT,
    `bbc70c60-b4a3-11e3-b08f-` TITAN_SELECTED_WEIGHT,
    `62f864a0-b4ab-11e3-bf54-` TITAN_SET_START_COUNTDOWN,
    `8d2f9b40-f8c5-11e3-b162-` TITAN_SLEEP_TIMEOUT,
    `e725d040-b4a7-11e3-a0ee-` TITAN_SOUND_STATE
  - Source: `com/veuxlabs/titan/android/model/dto/ble/BLEGattAttributes.java`
    (unobfuscated, jadx).
- `TITAN_CHALLENGE_KEY` hints at a pairing handshake — needs one HCI snoop to clarify.
- No actuation path: weight is selected by the mechanical handle dial, so BLE is
  read/config only. Safety class LOW.

## Cloud dependence
- Coaching videos / workout programs come from bundled assets + likely remote
  content; history sync may use a Nautilus backend (dead end). Core rep/weight data
  is local BLE.

## APK provenance
- Package: `com.veuxlabs.titan.android` — **version 2.1.1 (142)**, XAPK, 363 MB
  (mostly bundled workout videos), via apkeep `apk-pure`, 2026-08-07.
- SHA-256: `b6a7b64df55d1e6bd9c1358133166e8e622a1e9f314c05bdf6d031a4c6d2274f` (complete re-fetch; first download was truncated).
- Delisted from Play (404), fetchable from APKPure.

## Open questions
- Byte format of TITAN_EVENT / TITAN_REP_COUNT / TITAN_POSITION notifications.
- Purpose/need of TITAN_CHALLENGE_KEY (pairing auth?).
- Advertised name prefix (likely "ST560" or "Titan" — unverified).
