# Raden A22 / A28 — BLE Smart Luggage Research Notes

## What it is
Raden A22 (carry-on) and A28 (checked) polycarbonate suitcases, launched
March 2016. Smart features: integrated scale (weigh by lifting the
handle), BLE proximity/location awareness, removable 7,800 mAh battery
bank with 2x USB. **No motorized lock** — unlike Bluesmart, the app only
reads scale/proximity/battery; there is no remote unlock surface.
Features per Digital Trends:
https://www.digitaltrends.com/phones/raden-smart-luggage/

## Why it's abandoned (dated sources)
- 2018-01-15: US airline smart-luggage battery rules take effect.
- 2018-05-17: "Raden is no longer in operation... Our companion app will
  continue to pair to your bags." — i.e. bag pairing is local BLE by
  design; cloud was only for account/firmware/location history.
  Source: https://www.engadget.com/2018-05-17-smart-luggage-company-raden-shuts-down-airline-regulations.html
  and https://www.buzzfeednews.com/article/leticiamiranda/this-smart-luggage-company-is-going-out-of-business
- Apps now delisted from both stores (verified 2026-08-03: Play
  `com.raden*` 404; Apple Search API has no Raden luggage app), so the
  promised "app keeps pairing" only helps phones that still have it
  installed.

## Local BLE feasibility
- Shutdown statement implies direct app<->bag BLE pairing with no server
  in the loop for pairing itself. Scale readout and proximity are pure
  local BLE hypotheses.
- No known community RE (GitHub search 2026-08-03: nothing; no
  Gadgetbridge/HA integration). Greenfield.
- Lower stakes than lock devices: worst case the bag is just a suitcase.

## APK details — NOT fetchable (verified 2026-08-03)
- Candidate ids `com.raden`, `com.raden.android`, `com.raden.app`,
  `com.raden.travel`, `com.raden.luggage` all 404 on Play.
- apkeep (apk-pure), APKPure slugs, APKCombo slugs, Aptoide API: all
  negative. Recovery = adb pull from an owner handset.

## Safety class
LOW. No actuation; read-only telemetry (weight, proximity, battery).

## Open questions
- BLE name prefix / service UUIDs — unknown; needs nRF Connect scan.
- Did the app need a Raden cloud account before first pairing? If yes,
  resurrected-local tooling must bypass that gate.
- Which BLE module/firmware (likely off-the-shelf BLE SoC; scale data is
  probably a trivial notify characteristic).

## Next steps
1. nRF Connect scan of an A22/A28 (common on eBay/secondhand).
2. If a phone with the app survives: HCI snoop a weigh + proximity session.
3. Otherwise derive scale encoding empirically (notify bytes vs known weights).
