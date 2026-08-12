# Egofit Walker (M1 / M1T under-desk treadmill) — Research Notes

## What it is
Egofit (egofitwalker.com, plus regional storefronts) sells the Walker Pro /
Walker Plus M1 / M1T — very small under-desk walking pads with a fixed 3–5%
incline, 2.0 HP motor, ~25 kg. Ships with a wireless remote and a companion
BLE app ("Egofit" / Egofit mobile APP per product pages). Vendor active:
egofit.co.uk storefront updated 2026-01, eBay/Amazon listings into 2026.

## Why it's at risk
- Not abandoned — small-brand **cloud/longevity risk**. Egofit is a niche
  single-product-line vendor; the app is poorly rated on Google Play per a
  hands-on review (Terence Eden, 2023-08-08), and small vendors routinely
  let apps rot.
- Notably, the app does NOT hard-gate on an account: the same review reports
  it works with a fake email and skipped demographics — i.e. the BLE path is
  effectively local-first already; the cloud is only a stats/social garnish
  (a weird social leaderboard feature exists).
- Safety context: workwhilewalking.com's 2023-03-02 review called the Walker
  Pro's deck dangerously short and questioned UL certification — any local
  control work should keep the belt-length limits in mind.

## Local BLE feasibility
- Confirmed BLE app control (start/stop/speed + programmed workouts) per the
  Eden review and product listings.
- No public protocol RE and no QZ/Home Assistant driver found (checked
  qdomyos-zwift src/devices, 2026-08-04).
- Verdict: feasible greenfield target. App account-free behaviour suggests
  no server handshake in the BLE path; likely a simple UART-style command
  channel.

## APK details
- **Package**: `io.egofit.app` ("Egofit" on Google Play; surfaced in Play
  search 2026-08-04)
- **Fetch status**: NOT acquired. apkeep/APKPure could not download
  `io.egofit.app` (two attempts, 2026-08-04 — package exists on Play but is
  absent or blocked on APKPure). Options: google-play source with
  credentials, an adb pull from an owner handset, or an APK mirror.
- Difficulty impact: unknown until the APK or an HCI snoop is available;
  raises the RE cost from "triage" to "capture required".

## Open questions
- BLE name prefix, service/characteristic UUIDs (scan or APK).
- Whether programmed workouts are computed app-side (then local RE recovers
  everything) or pushed as opaque scripts.
- Any relationship to the common FitShow/iConsole-class platforms (several
  small treadmill brands resell the same controller boards).

## Sources
- shkspr.mobi review, 2023-08-08: BLE app works with fake email; poor Play rating
- workwhilewalking.com review, 2023-03-02: deck-length safety concerns
- egofitwalker.com / egofit.co.uk product pages (app control; active 2026)
- Play Store search: io.egofit.app (2026-08-04)
