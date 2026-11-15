# LG Pocket Photo (PD2xx) — Research Notes

LG's ZINK 2x3" pocket printer line: PD233/PD239 (2012-13), PD241,
PD251, PD269 (2015-17). All discontinued. LG exited the smartphone
business in April 2021 (wound down July 2021) and the companion app has
been abandoned with it: last release **3.2.5 (~2019)**, delisted from
Google Play and APKPure (APKPure returns zero versions for the package
id as of 2026-08). Still installable from Aptoide (see below).

## APK Provenance
- **Package**: `com.lge.media.lgpocketphoto` ("LG Pocket Photo")
  (the older id `com.lge.pocketphoto` is also referenced historically;
  the 3.2.5 build uses `com.lge.media.lgpocketphoto`)
- **Version**: 3.2.5-release (vercode 381)
- **Source**: Aptoide public API + pool CDN (store "appupdater");
  **MD5 `9db88222b9df6c2f38cc61f41525a8c6` matches Aptoide metadata**,
  signature owner "CN=lgPocketPhoto, O=LGE, C=ko" — genuine LGE build
- **APK SHA-256**: `737bd11208e990b75feffaae940778c8eaec3f473021fcdebae98dcb2d4ab806`
- NOT fetchable via apkeep (apk-pure lists no versions; google-play
  source untested). Difficulty impact: moderate — APK survives on Aptoide.

## Transport (from APK strings, triage-level)
- **Bluetooth Classic**, same dual-channel pattern as the Polaroid Zip:
  - SPP `00001101-...` (control/status)
  - OBEX OPP `00001105-...` (image push; full OPP client+server stack in
    `com/lge/media/lgpocketphoto/bluetooth/` and `.../oppserver/`)
- OBEX **authentication classes present** (`PasswordAuthentication`,
  `Authenticator`, AUTH_CHALLENGE strings) — the printer may demand an
  OBEX password on PUT, which would explain anecdotal "only the app can
  print" reports. No hardcoded password found in a strings pass; likely
  derived (MD5 challenge-response per OBEX spec). Needs HCI snoop.
- iOS prints to it and the PD251 manual mentions Windows support — the
  2012-2015 era implies classic BT throughout, no BLE seen in the APK.

## Local control feasibility
- **Via the app**: fully local (no LG account needed to print). Confirmed
  by design; app works offline.
- **Generic OPP push from PC**: plausible but unproven; OBEX auth may
  block it. Highest-value next experiment: pair (no PIN / 0000) and
  `obexftp`/`ussp-push` a JPEG; capture HCI snoop of an app print for
  comparison.
- Protocol framing on the SPP control channel: NOT yet extracted
  (PrintActivity$PRINT_STATUS exists; decompile follow-up needed).

## Cloud / account dependency
- None for printing. (Social-sharing features aside, print path is local.)

## Open questions
1. OBEX PUT auth: required? password derivation?
2. SPP control channel framing (status query / print command bytes).
3. Which PD models differ (PD269 "Popo 3" may tweak the handshake).

## Sources
- Aptoide listing (package id, vercode, LGE signature, MD5):
  https://ws75.aptoide.com/api/7/apps/search/query=lg%20pocket%20photo
- LG HK product page (PD251, app requirement):
  https://www.lg.com/hk_en/pocket-photo-printer/pd251/
- LG official manual mirror: http://popoguide.lge.com/html/pd251/en/en_sub06_02.html
- LG mobile exit (2021): widely reported; e.g. LG newsroom April 2021.
- Old app mirror (v3.2.5 metadata): https://lg-pocket-photo.soft112.com/
