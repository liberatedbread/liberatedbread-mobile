# Kindara Wink — BLE Basal Fertility Thermometer — Research Notes

## What it is
Wink is an oral basal body temperature (BBT) thermometer that syncs over BLE to the
Kindara fertility-awareness app (shipped Dec 2015, ~$69). The app charts BBT/cervical
fluid for conception or natural family planning; it also works with manual entry, so
Wink is the only BLE hardware in the ecosystem.

## Why it's abandoned / at-risk (dated sources)
- Kindara acquired by Prima-Temp, 2018-10
  ([MobiHealthNews](https://www.mobihealthnews.com/news/prima-temp-bolsters-womens-health-platform-kindara-acquisition)) —
  Prima-Temp's own BLE fertility product (Priya ring) never shipped at scale.
- Prima-Temp became Favor (The Pill Club), went bankrupt; Kindara assets sold to
  Thirty Madison, 2023-08. The app survives under Thirty Madison but the Wink hardware
  is long out of production ("The Wink is no longer in production" —
  [nicolejardim.com](https://nicolejardim.com/kindara-wink/)).
- `com.kindara.pgap` returns 404 on Google Play (checked 2026-08-03) — the Android app is
  delisted; still mirrored on APKPure (latest 7.4.3). At-risk: survival depends on a
  telehealth acquirer keeping a niche charting app alive.

## Local BLE feasibility
- Wink pairs directly to the phone; temperature sync is a local BLE transaction — no
  cloud account is needed to take a reading (account only for backup/community).
  App functions fully offline with manual entry, so the BLE path is the only part that
  needs RE.
- No prior community RE found (no openScale/Gadgetbridge-style driver, no GitHub protocol
  writeups). Greenfield.
- DEX strings triage of `com.kindara.pgap`:
  - Heavy "Wink" string presence (181 occurrences) with BLE handling code.
  - Standard Battery service `0x180F` / `0x2A19`, Device Information chars, CCCD `0x2902`.
  - NOT found: standard Health Thermometer service `0x1809` / `0x2A1C` — so readings use
    a custom characteristic, TBD.
  - CSR/Qualcomm OTA-family UUIDs (`…-0002A5D5C51B` suffix: `EB03BC60-1BFB-11E5-…`,
    `DE66E600-FE03-11E4-…`, `B46E6240-DC0F-11E3-…`, `72DB69C0-2558-11E5-…`, etc.) —
    likely the thermometer's CSR-module OTA/DAT service family.
  - Plain 16-bit-style custom UUIDs `68d31a80-e647-11e5-b66e-0002a5d5c51b`,
    `aa17a540-01ba-11e6-9a9e-0002a5d5c51b`, `505d9040-01bb-11e6-a59b-0002a5d5c51b` —
    candidate Wink data characteristics.

## APK provenance
- **Package**: `com.kindara.pgap` (delisted from Play; on APKPure)
- **Source**: apkeep `-d apk-pure`, downloaded 2026-08-03
- **Latest version listed**: 7.4.3 (1.0.5 → 7.4.3 available)
- **APK SHA-256**: `f89302015bd2cfcf5353b54c29f9768b97076372fcfe6024033186230d9a8427` (~14 MB)

## Safety
- safety_class: MEDIUM. BBT charts inform contraception/conception decisions; a wrong
  reading has real consequences. Client must display values verbatim, never interpolate.

## Open questions
- Which custom characteristic carries the temperature, and its encoding (likely IEEE float
  or fixed-point °C ×100).
- Advertising name (likely "Wink") and service UUID — one nRF Connect scan settles it.
- Whether the app requires server login before pairing (degrow risk) — test the APK.
- Full jadx pass to map the CSR-family UUIDs (OTA vs data).
