# iKubu Backtracker — Research Notes

## What it is
- The original consumer bicycle rear-view radar (2014, Stellenbosch, South Africa).
  Two units: a seat-post radar module (with integrated flasher light) and a
  handlebar display module; the pair communicate over **Bluetooth** (per the
  industrial-design case study, [Wiseman Design](https://wiseman-design.com/project-view/backtracker/)).
  140 m detection range, LED bar shows approach speed/distance.
- Crowdfunded (~$127k), shipped in small numbers 2014-2015.

## Why abandoned (dated sources)
- 2015-01-14: **Garmin acquired iKubu's assets** ([Garmin press release](https://www.garmin.com/en-US/newsroom/press-release/corporate/2015-garmin-acquires-assets-of-ikubu-developer-of-backtracker-bike-radar/);
  [DC Rainmaker](https://www.dcrainmaker.com/2015/01/acquires-backtracker-company.html)).
- 2015: Garmin rebadged the tech as the Varia RTL500 radar and dropped the
  Backtracker brand, its Bluetooth head unit, and the promised open API. No
  Backtracker firmware or support has existed since.
- The product never had a cloud service at all — "abandoned" here means dead brand /
  no parts or firmware, not a cloud shutdown.

## Local BLE feasibility
- **Local-only by design**: radar→display link is direct Bluetooth between its own
  two modules; no phone, no account, no servers involved. It cannot be "cloud-bricked."
- RE opportunity: the radar module is effectively a BLE peripheral streaming vehicle
  speed/distance frames. Sniffing/reimplementing that link would let a phone or a
  modern head unit replace the (failure-prone, battery-degrading) Backtracker display,
  and would document the lineage of the Varia protocol. iKubu publicly promised an
  open API that never shipped (per DC Rainmaker coverage).
- Unknown: whether the inter-module link is BLE GATT or Bluetooth Classic SPP
  (2014-era design; "Bluetooth" only in sources). An nRF Connect scan of a live unit
  answers this in minutes.

## APK
- **None exists** — no companion app was ever released; nothing to fetch.
  (Verified: no iKubu/Backtracker listing on Play or mirrors, 2026-08-04.)

## Open questions
- BLE vs Classic; advertising name/UUIDs; frame format for target list (distance,
  closing speed per vehicle).
- Whether the Garmin Varia RTL500 ANT+ radar profile inherited the frame semantics
  (if so, the ANT+ Radar profile docs partially document behavior).
- Very small installed base — hardware access is the bottleneck for any RE.
- safety_class: MEDIUM (rider-awareness safety device; false negatives possible —
  treat any reimplementation as advisory only).
