# nonda ZUS Smart Tire Safety Monitor (+ ZUS BLE ecosystem) — Research Notes

## What it is
ZUS Smart Tire Safety Monitor: BLE TPMS with 4 external cap sensors, by nonda
("No NDA Inc."). Part of a wider BLE car-gadget family driven by the one
"ZUS Smart Driving Assistant" app: Smart Car Charger/locator, Smart Vehicle
Health Monitor (OBD-II), Smart Dash Cam, backup camera, TPMS.

## Why it is abandoned / at-risk
- `nonda.co` no longer shows any hardware business — as of 2026-08-04 the homepage
  is a generic "Cheaper Insurance Tracker" affiliate page. Hardware store gone.
- The ZUS app (still listed on Play) has pivoted into an insurance/rewards/subscription
  funnel ("nonda Bucks", $2.99/mo mileage log) — device support is vestigial.
- All ZUS features historically required a nonda account; trip/mileage data is
  cloud-backed. If the backend dies, account-gated features die.
- Sources: https://nonda.co (fetched 2026-08-04),
  https://play.google.com/store/apps/details?id=us.nonda.zus (listing, current),
  https://nonda.zendesk.com/hc/en-us/articles/360018705632 (legacy docs still up).

## APK provenance
- **Package**: `us.nonda.zus` ("ZUS - Save Car Expenses", formerly ZUS Smart Driving Assistant)
- **Version**: 8.20.5 (82005), XAPK (78 MB, 9 dex)
- **SHA-256**: `4c32bf5c4573105b7b2def06f37b9a075978ff24a9532c92e84e79b171127d0f`
- **Source**: apkeep / apk-pure

## BLE findings (static triage, strings over dex)
- Custom serial-style services present: `0000ffe0/ffe1`, `0000fff0/fff1/fff2`
  (HM-10-style BLE serial, typical for the OBD dongle and/or TPMS receiver).
- Telink OTA service family `00001c0x-d102-11e1-9b23-000efb0000a5` → devices use
  Telink SoCs with over-air update.
- Classic SPP UUID `00001101` also present (dash cam / older devices).
- TPMS cap sensors most likely broadcast adverts picked up by the phone directly
  (app description: "connects to the ZUS device through Bluetooth 4.0"); advert
  format not yet decoded.

## Local feasibility
Hypothesis: the TPMS sensors are passive BLE broadcasters (like the generic
Chinese cap sensors already decoded by the community — see
`generic-ble-tpms-caps` note), which would make local reading trivial once the
advert layout is captured. The OBD dongle is ELM-adjacent (repo's
obd2-bluetooth-adapter spec may already cover it). No prior community RE of the
ZUS TPMS format found — one HCI snoop or nRF Connect scan settles it.

## Open questions
- Do TPMS sensors need an app-initiated bond, or are adverts enough?
- Is account login enforced before the app will talk to a sensor? (dex shows
  account flows; enforcement point not traced)
- Which UUID family belongs to the TPMS receiver vs the OBD dongle?

## Safety
TPMS is safety-adjacent monitoring, read-only. MEDIUM.
