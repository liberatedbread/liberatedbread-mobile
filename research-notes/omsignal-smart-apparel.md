# OMsignal Biometric Smart Apparel — Research Notes

## What It Is
OMsignal (OM Signal Inc., founded 2011, Montreal) was one of the earliest smart-
clothing companies: the OMshirt (men's biometric shirt), OMbra smart sports bra
(2016), the OMrun coaching platform, and the white-label **Ralph Lauren PoloTech
shirt** (2015). Garments wove ECG, respiration and activity sensors into the
fabric; a snap-on "smart box" module streamed data to the phone over Bluetooth.
Shirt MSRP $249. Sources: [BetaKit (2016-01)](https://betakit.com/omsignal-announces-new-smart-bra-and-omrun-platform/),
[NCBI SeCS review, PMC7037315](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7037315/).

## Why It Is Abandoned
- **Out of business as of February 2019** —
  [MobiHealthNews (2020-08-20)](https://www.mobihealthnews.com/news/early-smart-clothing-firm-omsignal-out-business).
  Servers, app backend, and omsignal.com all died with the company.
- iOS app is delisted (absent from iTunes Search API, verified 2026-08-04).
- No Android app surfaces on Google Play search or any APK mirror (apk-pure,
  APKCombo) as of 2026-08-04.

## Local BLE Feasibility
- Data path was local: garment sensors → smart box → BLE → phone app; cloud was
  for account, calibration storage, and OMrun coaching analytics. Raw ECG /
  respiration / step streaming did not inherently need the cloud.
- **However**: multiple secondary reports note the apps "won't authenticate" and
  "calibration routines are irrecoverable" post-shutdown — i.e. the *stock
  software* is dead even where the hardware works. Any revival means replacing
  the client entirely.
- No community reverse engineering found (GitHub search 2026-08-04: only a Mila
  course ML project using donated OMsignal datasets, and an api-evangelist
  metadata stub — no BLE protocol work).

## App / Binary Status
- **Android: an Android app is not confirmed to have ever existed** — the
  OMshirt/OMbra era was iOS-first and every contemporaneous source references the
  iOS app. Guessed package ids (`com.omsignal`, `com.omsignal.omrun`,
  `com.omsignal.app`, `com.omsignal.om`) return nothing from apk-pure and are not
  in the Wayback Machine's Play Store index.
- iOS IPA: delisted; recoverable only from owner devices/backups. Bundle id
  unknown.
- Consequence: no binary to statically mine for UUIDs. Protocol RE must start
  from hardware (nRF Connect scan of the smart box) — IF the box advertises
  without an app-side pairing secret.

## BLE Details
- Transport: Bluetooth Smart (BLE) per the NCBI review and product literature.
- Reported signals: 1-lead ECG (~125 Hz per one secondary source), breathing
  (stretch sensor), 3-axis accelerometer, steps/calories derived.
- Advertising name / UUIDs: UNKNOWN. No public capture.

## Open Questions
- Did any Android build ship (e.g. for the PoloTech retail channel)? Finding one
  would convert this from greenfield RE to a static-analysis exercise.
- Does the smart box require app-authenticated pairing before streaming?
- ECG electrode condition after ~7 years: textile electrodes may be the real
  revival blocker, not software.

## Verdict
**Dead-app-only, hypothesis-grade.** Local BLE transport is plausible and the
sensor set (textile ECG) is unique in the category, but: company dead since
2019-02, no obtainable app binary on any platform, zero prior RE, and unknown
pairing behavior. Rate VERY HARD; document for completeness, prioritize behind
Nadi X.
