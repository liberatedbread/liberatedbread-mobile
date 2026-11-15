# FINIS Smart Goggle (powered by Ciye) — Research Notes

## What It Is
Swim goggles with a removable "Smart Coach" display module showing live lap count,
splits, stroke rate and clock in-goggle. FINIS hardware built on Ciye ("Coach In Your
Eye") technology; launched April 2021. Post-swim sync over BLE to the **Ciye app**
(iOS/Android); Strava/Apple Health export. Also sold as Smart Goggle Max (open-water
style).
- [Swimming World launch coverage, 2021-04-08](https://www.swimmingworldmagazine.com/news/finis-smart-goggle-now-available-new-technology-powered-by-ciye/)
- [Gadgets & Wearables review, 2022-01-18](https://gadgetsandwearables.com/2021/07/29/finis-smart-goggle-review/)
- [TRI247 review, 2023-04-01](https://www.tri247.com/triathlon-gear/swim-gear/finis-smart-goggle-review)

## Why It's Abandoned — CONFIRMED, DATED
FINIS announced ([SwimSwam, 2025-08-20](https://swimswam.com/one-last-lap-for-the-finis-smart-goggle/);
[FINIS blog update](https://www.finisswim.com/blog/an-update-on-the-finis-smart-goggle)):
- Smart Goggle is sunset; **last day of sales 2025-12-31**.
- The app "will remain fully functional" only for users who **registered in the app
  before 2026-01-31**. New users and new devices cannot be registered after that date.

That cutoff has now passed (today: 2026-08-07): any goggle not registered by
2026-01-31 can no longer be activated through the official path, and the app's
remaining lifetime is finite. Textbook cloud-gated abandonment.

## Local BLE Feasibility — PARTIAL / PROMISING
- In-water the goggles are self-contained: the display shows time/laps/splits without
  any phone or account. That functionality cannot die with the cloud.
- Post-swim workout extraction goes through BLE to the Ciye app, which requires a
  registered account — the part that is now closed to new devices.
- A local BLE client that talks to the Smart Coach module directly would bypass the
  registration gate entirely. No community RE found; the protocol is undocumented.
- The Ciye app's Android package id is unknown; it is not findable on Google Play
  search (2026-08-07) and apkeep guesses failed. ciye.co (Wix site) is up but shows
  no store links. APK acquisition is the blocker — likely needs an installed-device
  extraction or the iOS app. Difficulty: HIGH until an APK/IPA is obtained.

## APK Provenance
- App: "Ciye" (FINIS Smart Goggle companion), iOS + Android
- Android package id: UNKNOWN — not on Play search, no APKPure hit for guessed ids,
  no store link on ciye.co or finisswim.com pages
- **APK not acquired.** If obtained, expect BLE UUIDs to fall out of static analysis
  quickly (same category of app as com.finisinc.live).

## What Needs Cloud
Account registration (mandatory for app use; closed since 2026-01-31), swim-history
storage, Strava/Apple Health export, firmware updates presumably.

## Open Questions
- Ciye Android package id / APK source (check APKCombo, AppBrain history, extracted
  from a device with the app installed).
- BLE GATT map of the Smart Coach module (service UUIDs, workout pull, config).
- Whether already-registered accounts still authenticate (app "remains functional" —
  but for how long, and is registration validated server-side per device?).
- Relationship between Ciye and FORM: FINIS's own marketing compares against FORM;
  Ciye tech lineage suggests FORM-compatible internals — worth checking whether the
  FORM app can see the module.
