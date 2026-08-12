# Snowcookie / SKEO Smart Ski Sensor System — Research Notes

## What it is
- **Snowcookie** (Snowcookie Sports SA, Switzerland; CEO Martin Kawalski): three-sensor ski telemetry system — one chest sensor + one per ski, all BLE, streaming to a phone app. Claims 105 measured parameters (edge angles, hip angulation, torso rotation, lateral balance). Launched 2018; used by Swiss/Japanese/US alpine teams.
  - [Startupticker 2018-08-14](https://www.startupticker.ch/en/news/august-2018/three-sensor-wearable-for-skiers-enters-the-market), [VentureBeat 2019-01-08](https://venturebeat.com/business/snowcookie-unveils-sensors-to-track-105-things-about-your-skiing)
- Relaunched Dec 2020 as **SKEO** with Bode Miller as investor/owner: free phone-GPS app + $449 sensor bundle; "Universal Alpine Ranking".
  - [PR Newswire 2020-12-01](https://www.prnewswire.com/news-releases/bode-miller-teams-up-with-snowcookie-sports-to-introduce-skeo-the-worlds-most-accessible-digital-ski-platform-301182535.html), [Sports Business Journal 2021-02-16](https://www.sportsbusinessjournal.com/Daily/Issues/2021/02/16/Technology/bode-miller-skeo-skiing-app/)

## Why it's (probably) dead
- As of **2026-08-07**: `snowcookiesports.com` serves a **GoDaddy parked-domain lander**; `getskeo.com` (the SKEO launch domain) 301-redirects to it. Wayback shows the real site live through **2023-08**, 301s starting ~2024-05, parked by 2026.
- Play listing `com.snowcookiesports.skeo` returns **404** (verified 2026-08-04).
- Caveat: a [Foley & Lardner / Mondaq piece dated 2026-02](https://www.mondaq.com/unitedstates/patent/1749004/) still describes Snowcookie as active Olympic-training tech — likely recycled marketing copy, but treat company death as **likely, unconfirmed**.

## Local feasibility — plausible, under-verified
- Sensors are BLE peripherals streaming to the phone; the app's value-add (AI coaching, rankings) was cloud-flavored, but raw sensor acquisition was local. The dex contains Nordic DFU references and a `snowcookie_connection_status_channel` — BLE stack present.
- **However**: the APK is a 180 MB Unity (IL2CPP) + Flutter hybrid (`libil2cpp.so`, `libflutter.so`, `libunity.so`, `libalgo_wrapper.so`). No UUID strings found in dex or IL2CPP global-metadata at triage depth — the BLE UUIDs are likely constructed in managed code or the algo wrapper. Extraction needs Il2CppDumper or dynamic capture. Rated **harder** than the other devices in this batch.
- No community RE found.

## APK Provenance
- **Package**: `com.snowcookiesports.skeo` ("SKEO")
- **Source**: apkeep, `apk-pure`
- **APK SHA-256**: `6d91eee8ca7ffdb08bca3dd453b4721daf1119cf93f939d59788834a8bff94ee` (179.6 MB)
- **Framework**: Unity IL2CPP + Flutter; native signal-processing lib (`libalgo_wrapper.so`); Firebase present
- Package ID recovered from archived getskeo.com (Wayback 2022-01-18 snapshot links to Play).

## Open questions
1. BLE service/characteristic UUIDs (needs Il2CppDumper pass or nRF Connect against live sensors).
2. Cloud-gating: does sensor pairing require an account/server handshake? (Firebase is present; premium tier existed.)
3. Chest vs. ski sensor role differentiation; raw IMU availability vs. fused metrics only.
4. Swiss registry (Zefix) check to confirm Snowcookie Sports SA dissolution.

## Status
- APK acquired: yes. Decompiled: **no** (IL2CPP+Flutter; beyond triage budget). UUIDs: not recovered.
- Verdict: viable target, high difficulty; local BLE plausible, cloud-gating unknown.
- safety_class: LOW (sports metrics only).
