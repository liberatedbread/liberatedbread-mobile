# JAXJOX Connected Strength Gear — Research Notes

## What it is
JAXJOX (Redmond, WA) made a family of BLE-connected strength devices managed by one
app (`com.jaxjox.mobile`):
- **KettlebellConnect / 2.0** — motorized adjustable kettlebell, 12–42 lb, weight
  selected by a rotating stacking core in the base (FCC ID 2ALO8-KB42).
- **DumbbellConnect** — adjustable dumbbell pair, same stacking-core concept.
- **FoamRollerConnect**, a smart scale, and a push-up device.
The app has per-device managers: `fitness/device/{kettlebell,dumbbell,foamroller,
smartscale,pushup,heartrate}` (jadx, app v3.3.3).

## Why it's abandoned
- BBB profile lists JaxJox Inc as **out of business**; complaint dated 2025-02-04
  (https://www.bbb.org/us/wa/redmond/profile/fitness-center/jaxjox-inc-1296-1000137664/complaints).
- Retailer Hy-Pro Sports product page (2025-08-19) states plainly:
  **"NOTE: PHONE APP NO LONGER SUPPORTED."**
  (https://www.hyprosports.com/products/adjustable-weight-kettlebell)
- `jaxjox.com` unreachable (connection fails, verified 2026-08-07); app absent from
  Google Play search and details page 404s (verified 2026-08-07).
- App was account/subscription-centric ($12.99/mo for classes); backend presumed dead.

## Local BLE feasibility — STRONG (with one caveat)
- **Hardware works without the app**: weight change is done with buttons on the
  base; a BestBuy reviewer explicitly noted "the app [isn't] required to own them."
  The BLE link is for rep/set tracking, workout metrics, and firmware.
- Recovered GATT UUIDs (jadx, app 3.3.3):
  - Legacy Kettlebell: service `0000FD00-...-00805F9B34FB`, chars `FD19`, `FD1A`
    (`LegacyKettleBellManager.java`). New KettleBellManager delegates to helper
    classes — UUIDs not yet pinned (may reuse FD00 or Nordic UART).
  - Smart scale: service `FC00`, chars `FC22`, `FC23` (`SmartScaleManager.java`).
  - FoamRollerConnect: Nordic-UART-style service `6E40FE01-B5A3-F393-E0A9-E50E24DCCA9E`,
    chars `6E408E02` / `6E408E03` (`FoamRollerManager.java`).
  - Heart-rate monitors: standard `180D`/`2A37`/`2A38`.
  - Also Fitbit tracker UUIDs `AAE28F00/01/02-71B5-42A1-8C3C-F9CF6AC969D0`
    (direct Fitbit BLE pairing feature, not JAXJOX hardware).
  - Nordic DFU library present (firmware updates).
- Caveat: the app gates on JAXJOX account login; if the backend is dead, the stock
  app may not reach the BLE screens. A local RE'd client bypasses this entirely.

## Cloud dependence
- Login, workout history, video classes, "FitnessIQ" scoring — cloud, presumed dead.
- Motorized weight selection: local base buttons; whether the app could also command
  weight change over BLE is an open question (if yes, treat writes as MEDIUM risk).

## APK provenance
- Package: `com.jaxjox.mobile` — **version 3.3.3 (3303)**, XAPK, 17.4 MB, via apkeep
  `apk-pure`, 2026-08-07. SHA-256: `39d8196131fb12a2b46c1d651ebef831e75459f8814f9f5a5d91ee72b7e1e498`.
- Delisted from Play (404), still fetchable from APKPure (3.1.0 listing dated 2022-08-20).

## Open questions
- New-generation KettleBellManager UUID set (helpers `h/i/j/k/l/m.java` + `x1.*`).
- Byte format of rep/set frames on FD19/FD1A (legacy) and the UART chars (foam roller).
- Whether BLE can command motorized weight changes.
- Advertised name prefixes per device ("JAXJOX", "KB-..."? — unverified).
