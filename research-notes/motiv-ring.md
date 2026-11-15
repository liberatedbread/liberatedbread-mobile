# Motiv Ring — Research Notes

Fitness/sleep smart ring (2017) by Motiv Inc., San Francisco. Titanium ring with
optical HR, 3-axis accelerometer, BLE; tracked activity, sleep, HR. Category: smart jewelry.

## Why it is abandoned
- Acquired by digital-identity startup Proxy on 2020-04-27; consumer sales halted
  immediately — [TechCrunch, 2020-04-27](https://techcrunch.com/2020/04/27/smart-ring-maker-motiv-acquired-by-digital-identity-company/),
  [MobiHealthNews, 2020-04-29](https://www.mobihealthnews.com/news/motiv-shifts-its-smart-rings-health-tracking-biometrics-following-acquisition),
  [Wareable, 2020-04-29](https://www.wareable.com/wearable-tech/motiv-ring-sells-out-7958) ("no word of how long devices will be supported").
- By Feb 2021 the Motiv website was offline and the operation effectively dead —
  [the5krunner, 2021-02-10](https://the5krunner.com/2021/02/10/motiv-ring-gone/).
- Proxy itself was acquired by Oura in 2023 — [Fitt Insider, 2023-05-09](https://insider.fitt.co/oura-acquires-digital-identity-startup-proxy/) — so the
  consumer ring infrastructure is definitively orphaned.

## Local BLE feasibility
- The ring is BLE-only (no other radio); all phone interaction went through GATT.
- Per the manual ([mymotiv.com PDF mirror](https://mymotiv.com/static/assets/the-motiv-ring-users-manual.pdf)),
  the app is *required* to activate/pair the ring and to view/sync data. Whether
  activation is a local BLE handshake or requires the (dead) cloud account system is
  **the** open question; reports from 2021 suggest rings became unusable, which points
  at cloud-gated activation.
- No prior community RE found (generic "smart ring" GitHub projects target cheap
  Colmi/JC rings, not Motiv).
- **Verdict: plausible local control, but hard** — app unavailable + likely activation gate.

## APK provenance
- **Package**: `com.motiv` — **NOT genuinely acquired.** apk-pure returned a 302 KB
  unrelated 2013-era goal-tracker stub under that id (SHA-256
  `1d38f4e1861bad59d09c19341baedfff16aa1a53fe67885c0f30e14732e0e967`; manifest shows
  `activity_create_goal` etc.). The real Motiv app is not on apk-pure; removed from
  Google Play. Needs adb pull from an old device or an archive mirror.

## Open questions
- Activation/pairing flow: local BLE exchange vs server-authenticated?
- GATT map, sync protocol, and whether the ring stores data retrievable without activation.
- Firmware: ring charges on a proprietary dock; any DFU path?

## Status
- apk_acquired: **no** (mirror hit was a false positive); apk_decompiled: no.
- Safety class: LOW (passive sensing, no actuation).
