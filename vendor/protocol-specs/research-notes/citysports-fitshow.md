# CITYSPORTS Walking Pads (FitShow platform) — Research Notes

## What it is
CITYSPORTS is a high-volume Amazon/marketplace walking-pad and 2-in-1
treadmill brand (WP6/WP8/CS-WP9/ZX2/ZX3…, €150–250 class). The pads
advertise over BLE with the device name **"CITYSPORTS…"** (pairing
instructions in the CS-WP9 manual: long-press "-" on the armrest until the
Bluetooth device name appears) and are documented as "compatible with most
Bluetooth Smart mobile devices" — the wording used by pads built on the
**FitShow** white-label platform (FitShow (Xiamen) Information Technology
Co., Ltd). Brand is active (citysportspro.com storefront, 2026 listings).

## Why it's at risk
- Not abandoned, but the brand is a thin reseller layer: if CITYSPORTS
  disappears, the pads depend on whatever app platform the controller board
  speaks (FitShow or similar). FitShow itself is a Xiamen white-label app
  vendor — exactly the class of supplier whose server-side features vanish
  without notice.
- User-facing app requirement is light (pads have remotes), but app-only
  features (programs, tracking) die with the platform.

## Local BLE feasibility — strong prior art
- **qdomyos-zwift supports "Fitshow" treadmills with full speed and incline
  control** (Equipment Compatibility wiki: "Fitshow ? Yes … Incline Control
  Yes, Speed Control Yes"; Muscle Squad P300 explicitly listed as "Fitshow
  treadmill"). The open-source driver is at
  src/devices/fitshowtreadmill — the protocol is therefore already
  documented in open code and locally exploitable.
- Whether a given CITYSPORTS pad is a FitShow unit must be confirmed per
  model (scan for the service UUID QZ's fitshowtreadmill driver uses, or
  check the manual's recommended app name).
- Verdict: high-confidence local control for FitShow-based units, no new RE
  needed — port or reuse QZ's driver.

## APK details
- **Package**: `com.fitshow` ("FitShow: Treadmill Workout", FitShow (Xiamen))
- **Version**: 5.5.2 (versionCode 364), fetched 2026-08-04 via apkeep
  (APKPure XAPK, 184 MB)
- **XAPK SHA-256**: `46ea7cddf3bf3d642b9cc9e1d85d81176713978c50a4708adea9368fc2b01be9`
- Native app, single DEX, obfuscated; triage jadx pass did not surface BLE
  UUIDs cheaply. Unnecessary anyway — QZ's fitshowtreadmill is the better
  source of truth.

## Open questions
- Which CITYSPORTS SKUs are FitShow vs other controller boards (iConsole,
  ESLinker, own-brand)?
- FitShow service/characteristic UUIDs and frame format — lift from QZ
  fitshowtreadmill and record in a real spec if this device gets promoted.
- CITYSPORTS pads also include Bluetooth *speakers* (A2DP) — keep audio and
  control channels distinct when scanning.

## Sources
- CS-WP9 manual (device.report/manual/12622961): BLE name "CITYSPORTS…", app pairing
- Amazon/media-amazon CITYSPORTS manual: "compatible with most Bluetooth Smart mobile devices"
- QZ Equipment Compatibility wiki (Fitshow row) + src/devices/fitshowtreadmill
- Play Store: FitShow by FitShow (Xiamen) Information Technology Co., Ltd (2026-08-04)
- citysportspro.com storefront (active 2026)
