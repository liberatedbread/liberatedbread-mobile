# DeerRun / SupeRun Walking Pads (PitPat app) — Research Notes

## What it is
DeerRun and SupeRun are Amazon-native walking-pad / under-desk treadmill brands
(both tied to Joyfit Inc.). Their pads pair over BLE with the **PitPat** app —
a gamified racing/competition platform ("world's largest online competition
platform", cash prizes, Vision Pro tie-in). Hardware is widely sold and the
vendor is very much alive (2025–2026 PR and product launches).

## Why it's at risk / user-hostile (dated sources)
- Play Store listing for PitPat (`com.linzi.sport`, Joyfit Inc.), updated
  2026-07-29: recent reviews complain the treadmill is unusable without the
  app ("You have to install it to get the treadmill to work which is absurd"),
  forced AI coach, ads, subscription nags, and an account-cancellation flow
  that forces you to "leave the club" first (reviews from 2026-07).
- App data-safety section: collects personal info + health/fitness data,
  shares with third parties. The whole value-add (races, rewards) is
  cloud-mediated; if PitPat's servers die, the app's reason to exist goes
  with it, while the pads remain perfectly good hardware.
- This is a "cloud-at-risk by business model" case, not abandonment: the
  platform is venture-scale monetisation of a captive hardware base.

## Local BLE feasibility
- Pads connect to the phone over BLE; no Wi-Fi on the pad itself.
  Control is therefore local radio + cloud app logic.
- Prior art: **qdomyos-zwift (QZ)** has a dedicated `deeruntreadmill` device
  driver (src/devices/deeruntreadmill) — i.e. the BLE protocol has been at
  least partially mapped by the QZ project. Issue #3589 (2025-08-02,
  "PitPat-T01 treadmill") shows a DeerRun pad connecting to QZ (belt powers
  on) but speed control not yet working for that firmware revision.
- The pads do NOT appear to implement standard FTMS (QZ needed a custom
  driver; the FTMS-generic path doesn't drive them).
- Verdict: local control is plausible and partially demonstrated; the exact
  command set needs to be lifted from QZ's driver or an HCI snoop.

## APK details
- **Package**: `com.linzi.sport` ("PitPat", Joyfit Inc.)
- **Version**: 4.21.00 (versionCode 42100002), fetched 2026-08-04 via apkeep
  (APKPure XAPK)
- **XAPK SHA-256**: `895a563270d267ae8f6caa1b2f8943430ee74a645ccc501d0f40d38074a6866e`
- Native app (11 DEX, no Flutter). Triage string pass found the standard
  Bluetooth assigned-numbers UUID table and DeerRun/PitPat branding strings,
  but no custom treadmill service UUIDs in a cheap pass — the BLE layer is
  likely obfuscated or in native libs. Deeper jadx/native work needed, or
  port QZ's deeruntreadmill driver.

## Open questions
- Exact BLE name prefixes and service/characteristic UUIDs (QZ source or
  HCI snoop will answer both).
- Does the pad enforce any app-side handshake/token before accepting speed
  commands (the "app required" complaint suggests a possible unlock dance)?
- PitPat-T01 firmware revision differences (per QZ issue #3589).

## Sources
- Play Store: PitPat, com.linzi.sport (Joyfit Inc.), updated 2026-07-29 — reviews
- QZ issue #3589: github.com/cagnulein/qdomyos-zwift/issues/3589 (2025-08-02)
- QZ source: src/devices/deeruntreadmill
- pitpatfitness.com, deerruntreadmill.com (vendor sites, active 2026)
