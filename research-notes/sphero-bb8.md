# Sphero BB-8 (Disney-era droids) — Research Notes

## What it is
Sphero's Disney-licensed app-controlled droids: **BB-8** (2015), **Force Band** (2016), **R2-D2 / BB-9E / R2-Q5** (2017). BLE-controlled rolling robots. The dedicated Disney apps ("BB-8 Droid App by Sphero", "Star Wars Droids App by Sphero") are what died — the hardware speaks Sphero's standard BLE protocol.

## Why it is abandoned / at-risk
- Sphero **ended the Disney partnership in Dec 2018** (CNET, 2018-12-18) after layoffs (Denver Post, 2018-01: 45 staff, ~25%) and pivoted to education.
- The Disney droid apps were later **pulled from app stores entirely**; Sphero support tells owners it lacks the rights to redistribute them (user reports, 2023).
- Sphero's own [legacy-products page](https://sphero.com/pages/legacy-products) directs BB-8 owners to the **Sphero Edu** app, which is still maintained and controls BB-8 over local BLE **without any account**.
- Sphero (edu-focused, spun off Company Six in 2020) is a much smaller company than in 2015 — the whole consumer line is legacy, so Sphero Edu's continued support of 2015-era hardware is itself at-risk.

## Local BLE feasibility: EXCELLENT
- Sphero **published its BLE API** ("Sphero BLE API" documentation) and the community built on it:
  - [igbopie/spherov2.js](https://github.com/igbopie/spherov2.js) — JS SDK covering the BLE toy line incl. BB-8/R2-D2.
  - Numerous Python bridges (sphero_sprk / bluepy-based wrappers) — BB-8 speaks the same API as SPRK+ generation.
- GATT confirmed in `com.sphero.bb8` v1.3.2 DEX and matching Sphero's published docs:
  - **Robot Control Service** `22bb746f-2bb0-7554-2d6f-726568705327`
    - Wake: `…-2bb2-…`; TX Power: `…-2bb7-…`; Anti-DOS: `…-2bbd-…`
    - Commands write: `…-2bba-…` (family; note DEX shows 2bb0/2bb2/2bb6/2bb7/2bbd/2bbe/2bbf), Response notify: `…-2bb6-…`/`2bbe`/`2bbf`
  - **DFU Service** `22bb746f-2ba0-…` (chars `2ba1`, `2ba6`)
  - Secondary service `22bb746f-3bb0-…`
  - Advertising name prefix `BB-` (string `BB8_01` in app assets); classic SPP UUID `1101` also present (Ollie-era compat).
- Session flow: write Anti-DOS code, write TX power, write `01` to Wake — then standard Sphero command packets (roll/heading/RGB LED/raw motors/back-LED).

## APK provenance
- **Package**: `com.sphero.bb8` ("BB-8 Droid App by Sphero"), version **1.3.2** (versionCode 566) — final.
- **Source**: apkeep `-d apk-pure` (XAPK, 258 MB — heavy AR/video assets).
- **SHA-256 (XAPK)**: `668561f8cf6351edddac16b6d71026c28f3c2bcd7db46ead9bf1a89ae80cd699`
- APKPure history 1.0.1 → 1.3.2. Also worth fetching later: `com.sphero.starwars` (R2-D2/BB-9E app) and current `com.sphero.sprk` (Sphero Edu).

## What needs cloud
- Nothing for control. The dead Disney apps' "holographic" AR and voice-command features are app-local anyway; Sphero Edu needs no login for driving/programming.

## Open questions
- Exact per-characteristic roles inside the 2bbx family (write vs notify split across 2bb6/2bbe/2bbf) — published Sphero BLE API doc has this; verify against doc, not guesswork.
- Force Band (gesture controller) protocol — same service family, separate note if acquired.
- R2-D2 extras (dome rotation, tripod leg) command IDs — in spherov2.js.

## Verdict
Document. Cloud status is irrelevant to control; protocol published by the vendor; the orphaned-Disney-app angle is exactly the repo's mission. Easy spec from vendor docs + spherov2.js.
