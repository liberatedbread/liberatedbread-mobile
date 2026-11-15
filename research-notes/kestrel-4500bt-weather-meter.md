# Kestrel 4000-series BT (4500BT) — Research Notes

Handheld weather/environmental meters (Kestrel 4000/4200/4300/4500 "BT" builds)
with **Bluetooth Classic** for data offload, from Nielsen-Kellerman (NK).
**Product line discontinued; zero cloud involvement; protocol undocumented —
hypothesis-grade note.**

## Abandonment / cloud status
- The 4000 series is discontinued; NK replaced it with the 5000 series, whose
  "LiNK" models use BLE + a current app ecosystem. NK the company is alive and
  well — this is a product-line orphan, not a dead company.
- Period catalog copy: "Data upload (with optional PC interface or integrated
  Bluetooth wireless technology)" ([NauticExpo catalog excerpt](https://pdf.nauticexpo.com/pdf/instromet-weather-systems-ltd/kestrel-4500-measures/56423-98391.html),
  [Pine Environmental listing](https://www.pine-environmental.com/products/kestrel_4500_weather_meter_with_portable_vane_mount)).
- Never any cloud: data offload was to bundled **Kestrel Communicator** Windows
  software (or the serial "PC interface" cradle). The Bluetooth units "include
  the software necessary to communicate wirelessly"
  ([Field Environmental](https://www.fieldenvironmental.com/equipment-rentals/survey-and-measurement/weather-monitoring-handheld/kestrel-4500-pocket-weather-tracker.html)).
- Note: period sellers warn the BT units are "not MAC/Apple compatible" —
  consistent with pre-MFi **Bluetooth Classic SPP**, not BLE
  ([bioweb listing](https://www.global.bioweb.co/products/kestrel-4500-pocket-weather-environmental-meter)).

## Transport hypothesis
- Bluetooth Classic SPP (BT 2.0-era radio inside the meter; Communicator
  software used a virtual COM port on Windows).
- The same-era **wired** PC interface speaks a documented-ish ASCII serial
  protocol (Kestrel 4000 series serial protocol has been discussed in ballistics
  communities); the BT build most likely tunnels the same protocol over SPP.
- No public RE of the BT variant found. No Android app ever existed.

## Companion software
- Kestrel Communicator (Windows, free, NK-hosted; still mirrored on NK's site
  for legacy meters at time of writing — availability not re-verified).
- No mobile app for the 4000-BT series; nothing to fetch with apkeep.

## Feasibility
- **MEDIUM-HIGH, unverified.** If the SPP hypothesis holds, an `rfcomm` channel
  plus the wired serial protocol commands (data dump / live reading polling)
  should work with zero vendor software. One HCI snoop against Communicator
  would confirm framing within an hour.
- The meter remains fully functional standalone (on-device logging of up to
  ~2900 data points) regardless of any software.

## Open questions
- Confirm SPP UUID (expect `00001101`) and whether pairing uses PIN `1234`/0000.
- Map wired-serial command set onto the BT link; check flow control.
- Exact EOL date of the 4000 series (replaced ~2014 by 5000 series; not verified
  against a dated NK source).

## Sources
- [NauticExpo — Kestrel 4500 catalog excerpt](https://pdf.nauticexpo.com/pdf/instromet-weather-systems-ltd/kestrel-4500-measures/56423-98391.html)
- [Pine Environmental — Kestrel 4500 listing](https://www.pine-environmental.com/products/kestrel_4500_weather_meter_with_portable_vane_mount)
- [bioweb — Kestrel 4500 (BT Apple-incompatibility note)](https://www.global.bioweb.co/products/kestrel-4500-pocket-weather-environmental-meter)
