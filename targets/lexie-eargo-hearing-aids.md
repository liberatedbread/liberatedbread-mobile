# Lexie and Eargo OTC hearing aids (LXE Hearing wind-down) — target spec starter

## Target metadata
- target_id: lexie-eargo-hearing-aids
- app package_id(s): Lexie Android `com.hearxgroup.lexie` (Play 9.0.0,
  2026-09-01), iOS id 1525380701 / bundle `com.hearxgroup.lexiehearing`
  (9.0.1); Eargo Android `com.eargo.app.android` (Play 9.0.1, 2026-09-18),
  iOS id 1529890348 / bundle `com.eargo.app.ios` (9.0.3). Siblings: LINK by
  Eargo `com.eargo.link.release` (same 22 Oct notice) and the legacy Eargo
  Neo HiFi `com.eargo.app` (no wind-down text; do not confuse it with
  `com.eargo.app.android`).
- device class: over-the-counter hearing aids. Two unrelated hardware
  families under one failing vendor:
  - **Lexie B1 / B2 / B2 Plus "Powered by Bose"** (Novidan-built; B1 is a
    re-badged Bose SoundControl, B2 a new radio grant). Lexie B3 (Classic +
    BLE, phone-OS pairing) and Lexie Lumen (IntriCon hardware on the
    separate "Tuned" app) are different platforms and separate targets.
  - **Eargo 5 / 6 / 7 / SE / 8**: the aids have **no radio**. LINK by Eargo
    is a Bluetooth 5.3 earbud product paired through the phone OS and is a
    separate target.
- transport(s):
  - Lexie B-series: BLE direct from phone to each aid ("BLE plus proprietary
    technologies", 2.4 GHz GFSK; FCC IDs 2A7MGLB2001L/R for B2 and B2 Plus,
    2A7MGLB1001 for B1, grantee hearX USA). B2 and B2 Plus are also Apple
    MFi hearing devices and Android ASHA devices.
  - Eargo 5-8: phone-to-aid control is **one-way "custom encrypted"
    ultrasonic audio** from the phone speaker to the aids' microphones (the
    FDA 510(k) calls it the Eargo UltraSonic protocol), acknowledged by a
    tone; the only BLE link is phone-to-**charger** (Bluetooth 5.0 LE in the
    case), used for program sync, Sound Match application, firmware, device
    info and adding devices while the aids sit docked with the lid closed.
- local-only viability: **medium for Lexie B-series, low-medium for Eargo**,
  and **time-critical**. LXE Hearing (assignment for the benefit of
  creditors 2026-07-15) is winding down: Lexie app removal and cloud
  deactivation 2026-10-08, Eargo's 2026-10-22, app support for both through
  2026-10-22, manuals archives until 2026-10-30. Version 9 of each app is
  "expected to remain functional locally" on the phone where it was
  installed and synchronised before the date; older versions stop; the apps
  cannot be re-downloaded afterwards. Both Play listings were still live on
  2026-10-12, four days after the Lexie date.

## Does the work need the cloud up? (established 2026-10-12)
- **Lexie B-series: the cloud is not part of the Bluetooth link.** Pairing
  is a 3-minute open window after power-on plus an ordinary BLE bond with no
  PIN, serial, account or internet step in the manuals; the v9 release notes
  say volume and settings are stored on the aids themselves; Lexie's own
  2024 store reply says the app connects over Bluetooth without internet
  (iOS waits out a ~60 s timeout first). The cloud sits **in front of the
  app**: first launch needs a phone-number/password sign-in with a
  server-issued second factor, the documented first-time pairing flow comes
  after sign-in, and firmware came from LXE's servers. So a v9 install that
  is already signed in and already bonded to the owner's aids is enough to
  capture volume / environment / program traffic; a fresh, signed-out or
  never-paired v9 probably cannot get past the login screen once the backend
  is gone. Unknown: whether the proprietary GATT control plane adds a
  post-bond handshake, and whether the v9 session ever expires.
- **Eargo 5-8: not for day-to-day control, but the earlier stub premise was
  wrong.** In-ear adjustment is acoustic and local; a signed-in, synced v9
  drives it with no server. The charger-BLE half is where the cloud bites:
  the pre-v9 help centre said internet was needed to authenticate the
  connected devices and to write settings after Sound Match, and adding new
  or replacement aids binds them to a server-side account. LXE has not said
  what v9 changed beyond "expected to work locally if synced". Capturing
  the acoustic channel is an audio-recording job (phone speaker at 96 kHz or
  better), not an HCI snoop; whether a recorded command replays depends on
  what "encrypted" means (static scheme vs per-device key).
- **Fallbacks that need neither app nor cloud:** B2 / B2 Plus pair as MFi
  hearing devices on iOS (mic volume, presets, Live Listen) and as ASHA
  devices on Android 11+ with aid firmware >= 1.13.14 (service 0xfdf0,
  central-writable Volume characteristic, no vendor key). B1, Bose
  SoundControl and all Eargo models have no such fallback. The Bose Hear app
  (`com.bose.bosehear`) is delisted (404 on both stores, 2026-10-12).

## Known facts (public)
- Vendor notices (primary record; the BBB page cited earlier is behind a
  bot wall and showed no wind-down text when it loaded):
  [lexiehearing.com/us](https://lexiehearing.com/us) (dated 2026-09-02),
  [eargo.com](https://www.eargo.com/) (2026-09-15),
  [lxehearing.com](https://lxehearing.com/). All three tell owners to open
  the app while online and connected to the aids so the configuration
  synchronises for offline use; none mentions sign-in, new phones,
  reinstalling, pairing new aids or firmware.
- Lexie B2 manual: pairing from inside the app, 3-minute window after
  power-on, up to 20 phones remembered with automatic reconnect, hold World
  Volume down ~15 s to clear the device list (voice prompt confirms). The
  B2 Plus manual's cybersecurity section shows the app can itself put the
  aids into pairing mode.
  [B2 manual](https://lexiehearing.com/documents/user-manual/Lexie_Bose_B2_User_Manual.pdf) ·
  [B2 Plus manual (UHC mirror)](https://www.uhchearing.com/on/demandware.static/-/Sites-masterCatalog_UHCHearing/default/dwd8b61b8e/pdfs/lexie-bose-b2-plus-usermanual.pdf) ·
  [B1 manual](https://lexiehearing.com/documents/user-manual/Lexie_Bose_B1_User_Manual.pdf)
- Lexie sign-in gate: the B-series FAQ starts first-time setup with account
  creation and its pairing troubleshooting assumes network access; errors
  772-774 are cleared by signing out, clearing the aids' list and signing
  back in. A 2026-09-03 Play review reports v9.0 failing at login with a
  parse error. **Never sign a v9 install out.**
  [B2 FAQ](https://lexiehearing.com/us/support-lexie-b2-resources) ·
  [Play listing](https://play.google.com/store/apps/details?id=com.hearxgroup.lexie&hl=en_US)
- Lexie MFi / ASHA: [Apple MFi list](https://support.apple.com/HT210386) ·
  [Apple MFi use](https://support.apple.com/HT201466) ·
  [Lexie ASHA article](https://lexiehearing.com/us/library/navigating-android-streaming-compatibility-for-your-lexie-otc-hearing-aids) ·
  [ASHA spec](https://source.android.com/docs/core/connect/bluetooth/asha)
- Eargo architecture: [Eargo technical & regulatory info](https://www.eargo.com/assets/content/dam/eargo/pdf/Eargo_Technical_Regulatory_Info.pdf)
  (ultrasonic adjustments; radio in the charger) ·
  [FDA K221698](https://www.accessdata.fda.gov/cdrh_docs/pdf22/K221698.pdf)
  (EUS protocol; SoundControl predicate is app-to-aid BLE) ·
  [help: remote control](https://help.eargo.com/en/articles/5886840-remote-control-feature-in-the-eargo-app)
  (phone volume 20-100 % iOS / 60-100 % Android, no DND, charger not needed,
  acknowledgement tone) ·
  [help: why Bluetooth](https://help.eargo.com/en/articles/5161038-why-does-the-eargo-app-require-bluetooth-access) ·
  [help: why internet](https://help.eargo.com/en/articles/5163377-why-does-the-eargo-app-require-internet-access) ·
  [help: charger pairing](https://help.eargo.com/en/articles/5161051-searching-for-connecting-to-your-eargo-charger-via-bluetooth)
  (ordinary OS bond: scan, solid blue LED, accept the Pair pop-up) ·
  [help: software updates](https://help.eargo.com/en/articles/5160937-software-updates-in-the-eargo-app)
  (aids docked, lid closed, battery >= 25 %; breathing blue = programming).
- Eargo owner reports (Aug-Sep 2026) describe forced email-verified login
  before adjustments and a sign-in loop that blocked adjustment entirely;
  account linking arrived in app 4.0.0 (2024-01), login-stability work in
  5.2.7/5.2.8 (2026-06/07). The adjustment screens sit behind a
  server-backed sign-in. [App Store history](https://apps.apple.com/us/app/eargo/id1529890348)
- LINK by Eargo: Bluetooth 5.3 earbuds, phone-OS pairing, app optional,
  reset = 10 s charger-button hold with earbuds docked, FCC ID
  2BDFPEARGOLINK. [LINK guide](https://www.eargo.com/assets/content/dam/eargo/pdf/LINK_by_Eargo_Use_Care_Guide.pdf)
- All four LXE apps jumped straight to version 9 (Lexie Android 3.7.3 ->
  9.0.0; Eargo 5.3.0 -> 9.0.0): v9 is a marked wind-down build and the
  v9-vs-previous diff is where any offline/caching change lives. APKMirror
  and Aptoide carry neither app; hash-check any mirror copy against a Play
  install. No APKs are committed here.
- **No public protocol work exists** for Lexie, Eargo, Bose SoundControl or
  Bose Hear (GitHub searched 2026-10-12). The only Bose work (bosectl,
  bozo-proto) is BMAP for headphones, where an unauthenticated control path
  sits beside a cloud-keyed SET path on the same link — a pattern to look
  for in Lexie captures.
- No first-hand owner report dated after the 2026-10-08 Lexie cutoff was
  reachable (HearingTracker forum, Trustpilot, store reviews; Reddit and
  Facebook unchecked), so whether the Lexie cloud is actually off is
  unverified.

## Device discovery signals
- Lexie B-series: BLE advertisement during the 3-minute window; local name
  and vendor service UUIDs unknown. B2 / B2 Plus also expose ASHA 0xfdf0
  when enabled.
- Eargo charger: BLE advertisement while the lid is open / pairing (solid
  blue LED); name and services unknown. The aids themselves advertise
  nothing.
- Wi-Fi: none.

## Threat model + guardrails
- **Medical device.** A spec may carry volume, program and preset selection
  as the apps expose them to the wearer; nothing that changes gain beyond the
  fitting range, and no hearing-test logic. Owner's own aids only.
- Placeholder the aids' and charger's addresses and serials in every note.

## First experiments (ordered by deadline)
1) **Now**: on a dedicated Android phone (HCI snoop needs Android), install
   both v9 apps, sign in, pair, open the controls while online and connected
   so each app syncs. The Lexie sign-in attempt is the only available test
   of whether its backend went off on 8 Oct — record the result with date
   and time. Then lock the phone down: no auto-updates, never sign out,
   never clear data, never "forget" the devices. A second signed-in phone is
   cheap insurance.
2) **Before 2026-10-22** (Eargo server still up): HCI-snoop phone-to-charger
   BLE — OS bond, device-info read, a Program Sync, and a Sound Match apply
   if the owner wants one anyway — with the aids docked. Read the charger's
   FCC ID off its label.
3) **Before 2026-10-22**: record the Eargo acoustic channel at >= 96 kHz for
   each command (volume up/down per ear, programs 1-4, noise filter, mute),
   repeated on different days; replay a recording to the owner's own aids
   and listen for the acknowledgement tone. A replay that works means a
   static scheme and a tone generator can replace the app.
4) Lexie B-series (any time the v9 phone still reaches the controls): clear
   the aids' list, power on, HCI-snoop the app-initiated pairing, then
   reconnect, volume, environment change, treble/bass, directionality and
   the app's "put aids into pairing mode". Look for an application-layer
   exchange right after the bond.
5) Lexie B2 / B2 Plus fallback: pair as MFi on an iPhone and as ASHA on
   Android 11+; with a bonded BLE central read the ASHA ReadOnlyProperties
   and write Volume. Check the aid firmware version in the app now — the
   ASHA FOTA cannot be fetched once LXE's servers are gone.
6) Offline matrix on each v9 phone in airplane mode: controls reachable?
   reconnect? pair factory-reset aids? Eargo Program Sync completes? any
   re-prompt for sign-in? Log with dates; these are the first post-cutoff
   reports anyone will have.
7) **Before 2026-10-30**: save the vendor PDFs and help articles for your own
   notes and push them through archive.org; retailer mirrors (UHC Hearing,
   Best Buy) are the fallback. Facts and URLs go in the repo, never the PDFs
   or UI text.

## Protocol hypotheses (to validate)
- Lexie B-series: standard BLE bond (Just Works or LE Secure Connections),
  then a proprietary GATT control service; a Bose-BMAP-like layout with an
  unauthenticated control path is plausible given the lineage.
- Eargo: a fixed ultrasonic symbol set per command (replayable) versus a
  rolling or per-device-keyed code provisioned via the charger — the
  question that decides whether one owner's capture generalises.
- Eargo charger BLE: an OS bond then a vendor service for program tables and
  firmware; the server step may be an account check rather than key
  material.

## References (URLs only)
- https://lexiehearing.com/us
- https://www.eargo.com/
- https://lxehearing.com/
- https://www.hearingtracker.com/news/lxe-announces-discontinuation-of-eargo-and-lexie-what-users-know
- https://www.hearingtracker.com/news/eargo-and-lexie-parent-lxe-hearing-begins-u-s-wind-down
- https://www.accessdata.fda.gov/cdrh_docs/pdf22/K221698.pdf
- https://www.eargo.com/assets/content/dam/eargo/pdf/Eargo_Technical_Regulatory_Info.pdf
- https://help.eargo.com/en/articles/5886840-remote-control-feature-in-the-eargo-app
- https://help.eargo.com/en/articles/5163377-why-does-the-eargo-app-require-internet-access
- https://lexiehearing.com/documents/user-manual/Lexie_Bose_B2_User_Manual.pdf
- https://lexiehearing.com/us/support-lexie-b2-resources
- https://source.android.com/docs/core/connect/bluetooth/asha
- https://support.apple.com/HT210386
