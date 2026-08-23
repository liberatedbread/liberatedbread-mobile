# Generic ZigBee Soil Tester (Tuya TS0601 family)

> **Status**: Spec Available (from public sources; not replayed against hardware)
> **Protocol**: ZigBee 3.0, Tuya datapoint protocol on cluster `0xEF00`
> **Manufacturer**: Tuya-based white-label OEMs (GIEX, Qoto, HOBEIAN, COOLO, AOYAN, Haozee, …)
> **Manufacturer Status**: Active — but the vendor app path is optional and irrelevant for local control

## Overview

The generic "ZigBee Soil Tester / Soil Moisture Tester" garden probes sold
on AliExpress and Amazon — retail names include **ZG-303Z**, **HZ-SL04
"Haozee"**, **QT-07S "Qoto"**, **GXM-01**, **GX04/GX06 "GIEX"**,
**CS-201Z "COOLO"**, **AY-302Z/303Z "AOYAN"** — are almost always Tuya
**TS0601** datapoint devices. Every reading and setting rides the
manufacturer-specific Tuya cluster `0xEF00` (61184) as typed datapoints
(DPs); there are **no standard temperature/humidity ZCL clusters to poll**.

The good news: **no Tuya hub and no Tuya cloud is needed**. These are
standard ZigBee 3.0 sleepy end devices (2×AA) that pair directly to any
coordinator, and Zigbee2MQTT supports the whole family natively.

## The trap: retail names do not identify the protocol

The real identity is the **(modelID, manufacturerName)** pair read at
ZigBee interview: modelID is always `TS0601`; the manufacturerName
fingerprint selects the DP map. The string "ZG-303Z" appears as the model
name of **at least two devices with different DP layouts**, so never key
decoding off the box label.

| Group | Fingerprints (manufacturerName) | Retail names | What's on board |
|---|---|---|---|
| `TS0601_soil` (classic) | `_TZE200_myd45weu`, `_TZE200_ga1maeof`, `_TZE200_2se8efxh`, `_TZE200_9cqcpkgb`, `_TZE204_myd45weu`, `_TZE284_myd45weu`, `_TZE284_oitavov2`, `_TZE284_2nhqasjh`, `_TZE284_2se8efxh` | Qoto QT-07S, GXM-01, "3-in-1" probes | Soil moisture, soil temp, battery |
| `TS0601_soil_2` | `_TZE284_g2e6cpnw`, `_TZE284_sgabhwa6` | — | + alarm thresholds/sensitivity, report interval |
| `TS0601_soil_3` | `_TZE284_aao3yzhs`, `_TZE284_nhgdf6qr` (GX04), `_TZE284_3urschql` (GX06) | GIEX GX04/GX06 | GX06 adds a light sensor (DP 2) |
| `ZG-303Z` (HOBEIAN) | `_TZE200_wqashyqo` | ZG-303Z | + ambient air temp/humidity, calibration, sampling periods (DP 102–112 layout) |
| `CS-201Z` | `_TZE200_npj9bug3`, `_TZE200_wrmhp6b3` | COOLO CS-201Z, AOYAN AY-302Z/303Z | + calibration, humidity (not AY-302Z), warnings; 4-in-1 spin adds soil fertility |

## Hardware

| Property | Value |
|----------|-------|
| Model Number | `TS0601` (ZigBee modelID; retail labels are rebadges) |
| Radio | ZigBee 3.0, profile 0x0104, endpoint 1 |
| Power | 2×AA, sleepy end device (wakes on sampling interval) |
| Clusters (in) | `0x0000` Basic, `0x0004`, `0x0005`, `0xED00`, `0xEF00` (manuSpecificTuya) |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — standard ZigBee join, nothing vendor-specific |
| Method | `hub_pairing` (any coordinator: ConBee, SONOFF ZBDongle, CC2652, …) |
| Passphrase protection | not_applicable (no WiFi; the ZigBee network key is delivered by the coordinator's standard join) |
| Confidence | medium (public sources; not replayed here) |

Put the coordinator in permit-join, then **hold the sensor's button ~5–6 s
until the LED flashes**. Keep the device awake with button presses if the
interview stalls — these are hard sleepers. After pairing, match the
reported `manufacturerName` against the table above to pick the DP map.

**Factory reset**: nothing beyond the leave/rejoin gesture is documented
(confidence low). The same ~5–6 s button hold makes the device leave its
network and re-enter join mode — that clears the network binding (PAN ID /
network key). Whether calibration offsets survive is unverified; re-check
the writable DPs after rejoining.

**Rebinding to a new network**: leave-then-join; the old coordinator does
not need to be alive, and no cloud account is involved on either side.

## Protocol Summary

All application data is Tuya DP traffic on cluster `0xEF00`. A datapoint
record is `[dpid u8][type u8][length u16 BE][value]`; type `0x02` is a
big-endian u32 "value" (the carrier for every scaled integer), `0x04` is
an enum. Which dpid means what — and whether temperature is raw or ÷10 —
**depends on the fingerprint group**. Headline DPs:

| Group | Moisture | Temperature | Battery | Extras |
|---|---|---|---|---|
| classic | DP 3, % raw | DP 5, °C raw | DP 14 enum + DP 15 % | DP 9 unit (°C/°F, writable) |
| soil_2 | DP 3 | DP 5, °C ÷10 (also DP 110, °F ÷10) | DP 14 + 15 | DPs 101–109: alarm states, min/max temp & humidity alarms, sensitivities, report interval 5–60 min |
| soil_3 | DP 3 | DP 5, °C ÷10 | DP 14 + 15 | DP 9 unit; DP 2 brightness 0–4 (GX06 only) |
| ZG-303Z | DP 107 % | DP 103 air °C ÷10 | DP 108 % | DP 1 water warning, 102/104/105 calibrations, 106 unit, 109 air humidity, 110 soil warning %, 111/112 sampling periods 5–3600 s |
| CS-201Z | DP 3 | DP 5, °C ÷10 | DP 15 % | DP 9 unit, 102/104/105 calibrations, 106 dry flag, 109 humidity (not AY-302Z), 110–112 warnings/sampling; 4-in-1 spin: 112 fertility, 114 threshold, 115 warning enum (unverified) |

The full per-group tables with access directions and ranges are in the
machine-readable spec's `zigbee.dp_maps` block.

### Known firmware quirks

- Some units **report °F regardless of the temperature-unit DP**
  ([z2m #31965](https://github.com/Koenkk/zigbee2mqtt/issues/31965)).
- **Stale 0 values after a battery swap** until the device is
  re-interviewed (same issue).
- Some hardware **mis-scales the battery DP**; upstream uses the raw value.

## Zigbee2MQTT / ZHA support

- **Zigbee2MQTT: fully supported natively** for all groups above — the
  reference implementation for this family. Local, no cloud, no Tuya hub.
- **ZHA: partial, quirk-dependent.** Support rides on zha-quirks Tuya DP
  plumbing; several fingerprints (e.g. `_TZE284_oitavov2`,
  `_TZE200_npj9bug3`) only got quirks via 2025 community requests
  ([zha-device-handlers #4144](https://github.com/zigpy/zha-device-handlers/issues/4144),
  [#4541](https://github.com/zigpy/zha-device-handlers/issues/4541)) and
  users still fall back to custom quirks.
- deCONZ, Zigbee for Domoticz and Homey also work for the common
  fingerprints (blakadder compatibility DB).

## Tools Used

- [ ] No captures or app teardown — family documented from the
      zigbee-herdsman-converters source snapshot (sha256 in the spec's
      `sources`) and the Zigbee2MQTT device pages.

## References

- [Zigbee2MQTT: TS0601_soil](https://www.zigbee2mqtt.io/devices/TS0601_soil.html) (+ `_soil_2`, `_soil_3` siblings)
- [Zigbee2MQTT: ZG-303Z](https://www.zigbee2mqtt.io/devices/ZG-303Z.html)
- [zigbee-herdsman-converters src/devices/tuya.ts](https://github.com/Koenkk/zigbee-herdsman-converters/blob/master/src/devices/tuya.ts)
- [Blakadder DB: Qoto QT-07S](https://zigbee.blakadder.com/Yieryi_THE01840.html)
- [SmartHomeScene: GXM-01 review](https://smarthomescene.com/reviews/tuya-zigbee-plant-soil-sensor-gxm-01-review/)
- [zha-device-handlers #4144](https://github.com/zigpy/zha-device-handlers/issues/4144) / [#4541](https://github.com/zigpy/zha-device-handlers/issues/4541)
- [zigbee2mqtt #31965](https://github.com/Koenkk/zigbee2mqtt/issues/31965) / [#30576](https://github.com/Koenkk/zigbee2mqtt/issues/30576)

Machine-readable spec: `device-specs/devices/zigbee-soil-tester.yaml`
