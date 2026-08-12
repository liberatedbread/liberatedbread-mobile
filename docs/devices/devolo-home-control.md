# devolo Home Control

> **Status**: Spec Available (from public sources; not replayed against hardware)
> **Protocol**: Z-Wave Plus EU (868.4 MHz), manufacturer ID `0x0175`
> **Manufacturer**: devolo AG (Aachen, Germany)
> **Manufacturer Status**: Shutdown — Home Control cloud switched off 2025-12-31

## Overview

devolo Home Control was a German-market Z-Wave smart-home system (launched
2015): a Z-Wave-to-IP gateway (the MT2600 "Zentrale") plus ~14 device SKUs,
all of them rebadged standard Z-Wave Plus devices. devolo announced the end
in a [press release dated 2025-08-21](https://www.devolo.de/de/ueber-devolo/presse/2025/abschaltung-der-home-control-server):
the Home Control servers shut down on **2025-12-31**, and they did.

This is the cleanest possible rescue case: **every device except the hub is a
standard Z-Wave slave** and works with any third-party Z-Wave controller.
No firmware work, no exploits — exclude, re-include, rebuild automations.

## What died, what still works

| Function | State after 2025-12-31 |
|---|---|
| Vendor app + web portal | Dead; app delisted from the stores |
| Remote access, voice control, notifications | Dead |
| Reconfiguration (rules, scenes, schedules, adding devices) | Dead — even local management always went through the cloud |
| Pre-programmed schedules and if/then rules | **Still execute locally** on the MT2600 ("autopilot"), until something needs changing |
| mydevolo account backend | **Still running** (no announced shutdown date, "no guarantee" per Home Assistant) |
| Home Assistant `devolo_home_control` integration | Alive as a stopgap: local API on the gateway (mprm REST/WebSocket), but the credentials come from mydevolo — when that dies, it dies |

The official successor is **ROCKETHOME**: a paid migration service that moves
the hub into its own subscription cloud — **99 €/year plus ~30 € one-time
activation** ([rockethome.de/devolo-landingpage](https://rockethome.de/devolo-landingpage)).
Rules and scenes are not migrated and the supported-device whitelist has
gaps. Home Assistant's [shutdown alert](https://alerts.home-assistant.io/alerts/devolo_home_control/)
notes the ROCKETHOME service is not compatible with the HA integration and
recommends **manual migration to Z-Wave JS** instead.

## The app

`com.devolo.homecontrol` — delisted from the store fronts at the shutdown,
but the APK still downloads via the Play API by package id (checked
2026-08-04 with apkeep; sha256 starts `d6115cd03e19ae69`). Not worth
rescuing: static inspection shows a cloud-only Retrofit REST + RxWebSocket
client (`de.devolo.mprm.*`) against `homecontrol.mydevolo.com` and
`*.devolo.net` — there is no local control surface in the app. The gateway's
*local* API is already documented by
[devolo_home_control_api](https://github.com/2Fake/devolo_home_control_api),
the library behind the HA integration.

## SKU → OEM mapping

All devices report Z-Wave manufacturer ID **`0x0175`** (373, "devolo Home
Control" — see OpenZWave's
[manufacturer_specific.xml](https://github.com/OpenZWave/open-zwave/blob/master/config/manufacturer_specific.xml)).
The OEM identities below come from the
[openHAB/OpenSmartHouse Z-Wave device database](https://github.com/openhab/org.openhab.binding.zwave/tree/main/doc/devolo),
which files several devolo devices under their OEM thing-types. Confidence
is `reported` throughout — transcribed, not lab-verified.

| devolo SKU | Device | OEM identity |
|---|---|---|
| MT02600 | Zentrale (gateway) | devolo own design — **the only e-waste item** |
| MT02646 | Smart Metering Plug (1st gen) | Philio PAN11 |
| MT02792 | Smart Metering Plug (2nd gen) | Philio PAN11 family |
| MT02647 | Motion Sensor | Philio PST02-1B (motion + temp + lux) |
| MT02648 | Door/Window Contact | Philio PST02 family (contact variant) |
| 09813 | Smoke Detector | unverified (Philio-style command classes) |
| MT02755 | Humidity Sensor (temp + humidity) | unverified (Philio-style) |
| MT02756 | Water/Flood Sensor | unverified (Philio-style) |
| MT02652 | Wall Switch (2 rockers, battery) | Z-Wave.me wall-controller family (also POPP) |
| MT02653 | Key Fob (4 buttons) | Z-Wave.me KFOB (manual text is the KFOB's verbatim) |
| MT02759 | Flush-Mount Switch (in-wall relay) | Qubino-derived flush module |
| MT02761 | Shutter Control (in-wall) | Qubino-derived (Flush Shutter family) |
| — | Flush-Mount Dimmer | Qubino-derived (Flush Dimmer family) |
| MT02650 (art. 09356) | Radiator Thermostat | **Danfoss** — filed under manufacturer Danfoss in the database; LC-13 family |

## Migration cheat-sheet

The universal pattern: put the **new** controller into *exclusion* mode and
run the device-side exclusion procedure — this works even though the old
network is dead, because exclusion is initiated on the device. Then include
normally. Keep battery devices awake during the interview or it stalls.

| Device | Exclude | Include | Factory reset / notes |
|---|---|---|---|
| Metering Plug MT02646 | Front button 3× in 2 s | same | — |
| Metering Plug MT02792 | ON/OFF button 3× in 1.2 s | auto-inclusion ~2 min after power-up, or 3× in 1.2 s | Hold ON/OFF ≥ 10 s |
| Motion MT02647 / Contact MT02648 | Tamper key 3× in 1.5 s | same | Tamper key 4×, hold 4th until LED off (~3 s), release within 2 s |
| Smoke Detector 09813 | Program switch ≥ 1 s | same | The fiddly one: battery out/in, seat in mount, then press the transparent button; success = yellow LED + beep. Expect retries ([community thread](https://community.home-assistant.io/t/how-to-include-devolo-smoke-detectors/668418)) |
| Humidity MT02755 | Tamper key 3× in 1.5 s | first power-on does Network Wide Inclusion | — |
| Flood MT02756 | Tamper key 3× in 1.5 s | same | — |
| Wall Switch MT02652 | Any button 1 s | same | — |
| Key Fob MT02653 | Management mode: button 3, then short press 3 | Fresh: hold button 1 for 1 s | Management mode: button 3, then hold button 4 ~5 s. Re-do associations on the new network |
| Flush Switch MT02759 | Toggle I1 3× in 5 s (params kept) | auto ~2 min after power-up, or I1 3× in 5 s | I1 5× in 5 s within 60 s of power-up. Service button S only on 24 V SELV |
| Shutter MT02761 | Toggle I1 3× in 3 s | same | Re-run position calibration after migrating |
| Flush Dimmer | I1 3× in 3 s | auto ~2 min, or I1 3× in 3 s | **Never use the S button on 110–230 V mains** |
| Thermostat MT02650 | Short press middle button | same | Reported LC-13 recovery: batteries out, hold middle button while reinserting. Check your new controller can set the temperature offset (Climate Control Schedule CC) before migrating |

## Target hardware

- **Home Assistant Green + Z-Wave stick** (e.g. Connect ZWA-2) with Z-Wave
  JS — the migration path HA itself recommends; reported ~120–180 € total.
- **Homey Pro** (~399 €) — caveat: devolo-badged Philio devices report
  manufacturer ID `0x0175`, which current Philio Homey drivers don't match,
  so they [pair as "Unknown Z-Wave Device"](https://community.homey.app/t/philio-app-devolo-badged-philio-devices-pair-as-unknown-z-wave-device/148412);
  siren/flood drivers are open community requests.
- openHAB, homee, Hubitat, Z-Wave.me — all work; the openHAB database
  already contains full channel/parameter definitions for every SKU above.

Automations are **rebuilt from scratch** on the new system — only
ROCKETHOME migrates any configuration at all, and only partially.

## Hub disposal

The MT2600 Zentrale has no local rescue path: closed gateway, cloud-issued
credentials, app dead. Options are the ROCKETHOME subscription migration or
e-waste. Everything else in the estate should be migrated, not discarded —
the used market is flooded (hubs ~10 €, thermostats 5–22 €), which also
makes these devices cheap Z-Wave spares for anyone already on Z-Wave JS.

## References

- [devolo press release (2025-08-21)](https://www.devolo.de/de/ueber-devolo/presse/2025/abschaltung-der-home-control-server)
- [Home Assistant alert: devolo Home Control server shutdown](https://alerts.home-assistant.io/alerts/devolo_home_control/)
- [Home Assistant devolo_home_control integration](https://www.home-assistant.io/integrations/devolo_home_control/)
- [openHAB Z-Wave DB — devolo device set](https://github.com/openhab/org.openhab.binding.zwave/tree/main/doc/devolo)
- [OpenZWave manufacturer_specific.xml — 0x0175](https://github.com/OpenZWave/open-zwave/blob/master/config/manufacturer_specific.xml)
- [ROCKETHOME devolo migration offer](https://rockethome.de/devolo-landingpage)
- [devolo_home_control_api (local gateway API)](https://github.com/2Fake/devolo_home_control_api)

Machine-readable spec: `device-specs/devices/devolo-home-control.yaml`
