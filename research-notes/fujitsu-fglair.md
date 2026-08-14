# Fujitsu General FGLair Wi-Fi Modules (Ayla Networks) — Research Notes

## What it is
Fujitsu General mini-split WLAN adapters (UTY-TFSXW1 / UTY-TFSXW3 and
built-in "Smartphone Link" variants, SSID prefix `AP-WD/E…`) controlled by
the **FGLair** app. The modules run on **Ayla Networks** IoT firmware — the
same platform as HiSense AEH-W4B1/W4E1 modules (Beko, Westinghouse, Winia,
Tornado, York rebadges). FGLair is being **superseded by "AIRSTAGE Mobile"**
(newer adapters, SSID `AP-WH\E / AP-WJ\E`; UK installers reported FGLair
adapters hard to source from 2023) — so FGLair is a soft-abandonment case
and the local path is the interesting one.

## Local protocol (community-RE'd, confirmed)
[Ayla Networks LAN API](https://github.com/deiger/AirCon) (deiger/AirCon,
active since 2019; explicitly supports "Fujitsu FGLair" and fglair-eu app
code):
- After provisioning, the module maintains an **encrypted session to a LAN
  server** over local TCP (device-initiated; server advertises its IP to the
  unit) using a per-device **LAN key**. Status is pushed and commands pulled
  on that channel; deiger/AirCon terminates it and re-exposes the unit via
  HTTP/MQTT with full property set: power, work mode (FAN/HEAT/COOL/DRY/
  AUTO), set temp, fan speed, louvers, sleep/eco, ambient temp, error flags.
- HA integration path: deiger/AirCon as add-on with MQTT discovery; also
  ESPHome firmware for some Fujitsu adapters (martinhladil/esphome_fujitsu_ac)
  and Benas09/FujitsuAC as alternative local library.

## Cloud steps required (the catch)
- Provisioning (Wi-Fi join + account binding) requires the FGLair app and
  an Ayla cloud account — no documented offline provisioning.
- The per-device **LAN keys are fetched once from Ayla cloud** with the app
  credentials (`python -m aircon discovery fglair-eu <email> <pass>` writes
  a config file per A/C).
- After key extraction the units **can be firewalled off the internet
  permanently** (deiger README: "the A/Cs can be blocked from connecting to
  the internet, as it will no longer be needed"). So: one-time cloud step,
  then fully local. If Ayla ever kills the FGLair service, already-extracted
  keys keep working; new provisioning would break.

## APK
- `com.fujitsu.fglair` — **fetched via apkeep (APKPure), 2026-08-07**:
  XAPK v3.4.2 (versionCode 30156, minSdk 24, targetSdk 35),
  sha256 `7d73f9475173671dfde267ba6404abeea5440d0421ee20af89a58696ff10208a`.
  Native app; static triage not needed since deiger/AirCon already
  documents the LAN protocol. XAPK kept in `workspace/apks/`.

## Model/app split
- FGLair app ↔ adapters whose SSID does NOT start with `AP-WH\E`/`AP-WJ\E`
  (per Fujitsu FAQ 0123, general-hvac.com, accessed 2026-08-07).
- AIRSTAGE Mobile adapters: different platform, local status unknown —
  treat as un-researched (candidate for future RE).

## Safety
HVAC actuator control — MEDIUM.

## Sources
- github.com/deiger/AirCon (README; accessed 2026-08-07)
- fujitsu-general.com/global/products/fglair + general-hvac.com FAQ 0123
- HA community "Fujitsu AC units integration with HA" (2023-05: FGLair
  adapters being phased out for Airstage)
- github.com/Benas09/FujitsuAC (2025-07, local library alternative)
