# Anki Overdrive — Research Notes

## What it is
- **Anki Overdrive** (2015) and **Overdrive: Fast & Furious Edition** (2017): app-controlled slot-car-style racing robots on modular track. Predecessor **Anki Drive** (2013) uses the same BLE message family.
- Cars are fully self-contained (IR track sensing, on-car MCU); the phone sends speed/lane/lights/weapon commands over BLE. All AI opponents run **on-device in the app** — no cloud involvement in gameplay.

## Why it is abandoned / at-risk
- Anki Inc. shut down **April 2019** (~200 staff laid off; reported 2019-04-29, e.g. Recode/The Verge).
- Assets sold to **Digital Dream Labs (DDL)** in Dec 2019; DDL briefly relisted the app, then let it rot. Community reports DDL in terminal decline with servers intermittently/lastingly down (robotsaroundthehouse.com thread, 2023-07; ongoing complaints since).
- `com.anki.overdrive` is **no longer on Google Play**; mirrors only.
- The app itself never needed a working cloud for racing — cloud was only accounts/leaderboards. Local BLE control is completely independent.

## Local BLE feasibility: EXCELLENT (best-in-category)
- Anki **open-sourced the official C SDK** before collapse: [anki/drive-sdk](https://github.com/anki/drive-sdk) (message protocols + parsing).
- Extensive community RE:
  - [Aspern/anki-overdrive-api](https://github.com/Aspern/anki-overdrive-api) (Node, noble) — implements the full Drive SDK spec.
  - [xerodotc/overdrive-python](https://github.com/xerodotc/overdrive-python) (bluepy).
  - [super-anki/anki-sdk](https://github.com/super-anki/anki-sdk) (modern TypeScript).
  - [dschwen/OpenOverdrive](https://github.com/dschwen/OpenOverdrive) — open-source Android controller app, **actively updated (2025)**.
  - Home Assistant / Web Bluetooth ports exist (andy008/AnkiOverDriveJS).
- BLE GATT confirmed both in prior art and in APK v3.4.0 DEX strings (2026-08):
  - Service: `be15bee0-6186-407e-8381-0bd89c4d8df4`
  - Write (commands): `be15bee1-6186-407e-8381-0bd89c4d8df4`
  - Notify/read (responses, track-position events): `be15beef-6186-407e-8381-0bd89c4d8df4`
  - Also present: standard DIS (`180a`) and three unknown 128-bit UUIDs (`1f687216-…`, `30619f2d-…`, `68f0fd05-…` — likely app-internal, not GATT).

## APK provenance
- **Package**: `com.anki.overdrive` ("Anki OVERDRIVE"), version **3.4.0** (versionCode 1502) — final release.
- **Source**: apkeep `-d apk-pure` (XAPK, base `com.anki.overdrive.apk` inside).
- **SHA-256 (XAPK)**: `656e548cc9b10790bc34b67b7e643d8df388d633566bf81a7f126581d824abe2`
- APKPure lists full history 1.5.0 → 3.4.0.

## What needs cloud
- Nothing for driving. Multiplayer is local BLE (one phone per car set). App-account/leaderboard features are dead but irrelevant.

## Open questions
- F&F-edition weapon/EMP packet opcodes: covered by the SDK spec but worth verifying against live captures.
- Car firmware-update channel (app-hosted firmware blobs in the XAPK `Android/` assets?) — worth one look if OTA matters.
- DDL still nominally owns the trademark; status of any revived store listing is volatile.

## Verdict
Document. Protocol is public, local-only, multiple maintained implementations — this is a "write the spec from prior art + confirm with one HCI snoop" job, not an RE job.
