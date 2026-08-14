# Friday Lock (Friday Labs / Friday Home) — Research Notes

## What it is
Friday Lock (FLSS) — small retrofit smart lock designed by Bjarke Ingels Group
(BIG) for Danish startup Friday Labs; crowdfunded on Indiegogo 2015
(~$1.5M class campaign), shipped 2016; a "version 2" shipped ~2019.
BLE + Apple HomeKit, Wi-Fi via bridge/shell options; interchangeable shells.

## Cloud status: appears defunct (hypothesis, moderate confidence)
- Product listed "discontinued by manufacturer" (retail listings).
- Last credible sign of life: HomeKit News review of Friday Smart Lock v2,
  **Feb 2020**: https://homekitnews.com/2020/02/10/friday-smart-lock-version-2/
- As of 2026-08-03, `fridayhome.com` serves HTTP 404 (domain responds, no site).
- No announcement of acquisition or shutdown found; the company (Friday Labs ApS
  → "Friday Home") appears to have quietly wound down. Treat as "dead, weakly
  sourced" — no single authoritative dated shutdown notice located.

## Local BLE feasibility: plausible via HomeKit, unverified
- The lock was **Apple HomeKit**-certified (per contemporaneous reviews) — HAP
  over BLE runs locally, so HomeKit pairing via Apple Home or Home Assistant's
  HomeKit Controller is the most promising cloud-free control path.
- Vendor's own BLE protocol (Friday app) is not publicly RE'd; no GitHub drivers
  or HA/Gadgetbridge support found.
- Setup dependency unknown: if HomeKit pairing is initiated at the lock (standard
  HAP setup-code flow), the vendor cloud is not needed at all. If provisioning
  requires the Friday app account, unpaired locks may be stranded.

## APK: NOT FETCHED
- App gone from Google Play; not on APK Pure under plausible ids
  (`com.fridayhome`, `com.friday.home`, `com.fridaylabs.friday`, `dk.friday.home`
  all miss, 2026-08-03). Package id unconfirmed.
- Difficulty: HIGH for vendor-protocol RE; MEDIUM if HomeKit path pans out
  (standard protocol, no RE needed).

## Open questions
- Authoritative company-death source (Danish CVR registry check would settle it).
- Whether HomeKit setup code is printed on the lock/manual (enables cloud-free use).
- Any surviving Friday Home APK.
