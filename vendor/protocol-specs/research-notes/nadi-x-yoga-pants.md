# Nadi X Smart Yoga Pants (Wearable X) — Research Notes

## What It Is
Smart yoga leggings from Wearable X (a.k.a. Wearable Experiments, Inc., founded 2013,
New York / Sydney). Woven-in motion sensors at hip, knee and ankle plus a
rechargeable "Pulse" module clipped behind the left knee drive **haptic vibration
motors** that coach the wearer into poses. Companion app "Nadi X" pairs over BLE.
MSRP $249. Sources: [GadgetAny (2023-01)](https://www.gadgetany.com/best-smart-clothing/),
[NCBI SeCS review, PMC7037315 (2024-03)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7037315/).

## Why It Is At-Risk / Effectively Abandoned
- Gherzi smart-textiles industry review (2026-05-04) lists Wearable X as
  "**inactive ~2021**": <https://www.gherzi.de/bulletin/smart-textiles-four-decades-of-promise-funding-and-fractured-commercialisation/>
- The iOS app is abandonware: **v1.1, last updated 2018-02-01**, but — critically —
  **still listed on the Apple App Store today** (verified 2026-08-04 via iTunes
  lookup of app id `1314196363`, bundle id `com.wearablex.nadix`, seller
  "Wearable Experiments, Inc", minOS 10.0).
- The archived wearablex.com homepage (2019) only ever linked the iTunes app;
  **no Android version was ever released**. All "Android APK" leads are dead ends.
- Company has since moved on to metaverse/digital-fashion collaborations
  (DRESSX AR Nadi X, 2022) rather than supporting the hardware.

## Local BLE Feasibility — GOOD CANDIDATE
- Haptic coaching is inherently **local**: the phone sends vibration commands to the
  Pulse module and reads IMU data; no cloud round-trip is physically required for
  the core function. Nothing found suggests a cloud account is needed to vibrate.
- Cloud dependence is limited to content (pose library / progress history), if any.
- The device predates BLE-pairing hardening trends; a plain GATT service with
  writeable motor-intensity characteristics is the expected shape (HYPOTHESIS).
- Rescue path is realistic: while the app remains on the App Store it keeps working;
  the protocol can be captured with a BLE proxy/sniffer (nRF Connect + sniffer
  firmware, or an iOS PacketLogger capture) and reimplemented as a local client.

## App / Binary Status
- **Android APK: none exists.** apkeep attempts against `com.wearablex.nadix`
  (apk-pure) fail — nothing to fetch on any Android mirror.
- iOS IPA `com.wearablex.nadix` v1.1 is the only app binary; acquirable from the
  App Store with an Apple ID while listed, or from owner device backups.
- No community reverse engineering found (GitHub search 2026-08-04: nothing).

## BLE Details
- Transport: Bluetooth Low Energy (NCBI review: "Bluetooth"; module "clips into the
  host plate behind the left knee").
- Advertising name / service UUIDs: UNKNOWN — no public capture. Needs one owner
  with an nRF Connect scan; expect a custom 128-bit service with per-motor
  characteristics and an IMU stream.

## Open Questions
- Does the app require an account/login server before BLE unlock? (Download the
  IPA and inspect, or ask an owner.)
- GATT map: how many haptic channels, and is pose detection done in-app from raw
  IMU or on-module?
- Is the Pulse module firmware updatable (DFU) — i.e. is there a Nordic/Dialog SoC
  under the potting?
- App Store listing could vanish any day (company inactive) — archive the IPA now.

## Verdict
**Viable, hypothesis.** The most rescuable device in the dead-smart-clothing
category: actuator-style local control, app still obtainable, trivial physical
layer. Difficulty gated entirely by iOS-only binary + lack of any public GATT capture.
