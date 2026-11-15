# Parrot Flower Power — Research Notes

BLE plant sensor (sunlight, air/soil temperature, soil moisture, soil fertility via conductivity). AAA battery, IPX5. Released 2013 by Parrot (French drone company); discontinued circa 2016–2017. Sibling product **Parrot Pot** (BLE smart flower pot) shares the ecosystem and is also discontinued — see open questions.

## Why it's abandoned
- Hardware discontinued: [Parrot Flower Power Discontinued — SmartThings Community, 2017-02-23](https://community.smartthings.com/t/parrot-flower-power-discontinued/78929). Parrot exited consumer plant sensors entirely (only the [user guide PDF](https://www.parrot.com/assets/s3fs-public/2021-09/flower-power_user-guide_uk.pdf) survives on parrot.com).
- The companion app `com.parrot.flowerpower` is delisted from Google Play. As of 2026-08-03, APKPure lists **zero downloadable versions** for the package (`apkeep -l` returns an empty table; download produces no file and no error). Old copies may exist on manual mirrors (APKMirror etc.) — unverified.
- The Parrot cloud (plant database, historical sync, account) is presumed dead/degraded; the app required an account for the plant-care features.

## Local BLE feasibility: EXCELLENT (best-documented device in this category)
- Parrot **officially published** the BLE protocol: `developer.parrot.com/docs/FlowerPower/FlowerPower-BLE.pdf` (linked from the WatchFlower docs below) and released an official client lib [Parrot-Developers/node-flower-power](https://github.com/Parrot-Developers/node-flower-power).
- Community prior art is deep and current:
  - [sandeepmistry/node-flower-power](https://github.com/sandeepmistry/node-flower-power) — full Node noble client (live mode, calibrated live mode, history download, LED pulse).
  - [emericg/WatchFlower](https://github.com/emericg/WatchFlower) — actively maintained (Flathub build dated 2026-01-06); its [flowerpower-ble-api.md](https://github.com/emericg/WatchFlower/blob/master/docs/flowerpower-ble-api.md) documents the complete GATT table with handles (source of the YAML here).
  - [hobbyquaker/flowerpower2mqtt](https://github.com/hobbyquaker/flowerpower2mqtt), [mbrentini/homeassistant_parrotflowerpower](https://github.com/mbrentini/homeassistant_parrotflowerpower) — Home Assistant path.
- All sensor readings (live + calibrated live, fw ≥ 1.1.0) and on-device history are readable over pure GATT — no cloud, no account. Only the plant-care *recommendations* came from the Parrot cloud plant database, and those are not needed to harvest sensor data.

## BLE summary (full GATT in the YAML)
- Advertised name: `Flower power AABB` (AABB = last MAC octets). Discovery signal: service UUID `39e1fa00-84a8-11e2-afba-0002a5d5c51b` in advertisement data.
- Live service `39e1fa00-...`: sunlight (fa01), soil EC (fa02), soil temp (fa03), air temp (fa04), soil moisture (fa05), measure period RW (fa06), LED RW (fa07), last-move (fa08); fw ≥ 1.1.0 adds calibrated characteristics fa09–fa0e.
- History service `39e1fc00-...`: entry count/indices + session info for downloading stored samples.
- Clock service `39e1fd00-...`; OTA service `f000ffc0-0451-4000-b000-000000000000` (TI OAD).
- Quirk: device drops the link ~1 s after the last BLE request — keep requests flowing or reconnect per poll.

## APK details
- **Package**: `com.parrot.flowerpower` — **NOT fetchable** via apkeep (apk-pure empty; huawei-app-gallery empty). This barely matters: the protocol is fully documented from Parrot's own doc + node-flower-power source, so no decompile is needed.

## Open questions
- Parrot Pot GATT differs ([node-flower-power#22](https://github.com/sandeepmistry/node-flower-power/issues/22) — it does not advertise the fa00 service UUID); worth a follow-up note if units surface.
- Raw (uncalibrated) value conversion formulas vs the calibrated fa09+ characteristics — WatchFlower source has the math.
- Whether the official BLE PDF is still reachable; archive a copy of the *facts* (not the PDF) into a device spec.

## Sources
- https://community.smartthings.com/t/parrot-flower-power-discontinued/78929 (2017)
- https://github.com/sandeepmistry/node-flower-power
- https://github.com/Parrot-Developers/node-flower-power
- https://github.com/emericg/WatchFlower + docs/flowerpower-ble-api.md
- https://github.com/hobbyquaker/flowerpower2mqtt
- https://github.com/mbrentini/homeassistant_parrotflowerpower
- https://www.parrot.com/assets/s3fs-public/2021-09/flower-power_user-guide_uk.pdf
