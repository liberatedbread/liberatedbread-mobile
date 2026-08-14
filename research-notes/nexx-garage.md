# Nexx Garage (NXG-100/200/300) — Research Notes (DUD: cloud-only, vendor unresponsive)

## What it is
Nexx Smart Garage NXG-100/200/300: WiFi add-on garage controllers with a
wireless door sensor. Vendor site getnexx.com still sells NXG-300
(reachable 2026-08-07).

## Verdict: DUD for local control
- **No LAN API** is documented or implemented anywhere. Every community
  integration talks to the Nexx cloud: the RE'd
  [@jontg/nexx-garage-sdk](https://www.npmjs.com/package/@jontg/nexx-garage-sdk)
  (npm, 2022-12) is explicitly a client for Nexx's cloud API
  (username/password → cloud token → device commands). SmartThings and
  IFTTT paths are likewise cloud.
- Security posture is a red flag rather than an opportunity: CISA
  ICSA-23-094-01 (2023-04) covers critical Nexx cloud vulnerabilities
  (anyone could open doors armed with an email/device ID; hardcoded MQTT
  credentials in firmware). The researcher reported the vendor **ignored
  all contact** from him, CISA, and press (borncity.com summary,
  2023-04-06). Unpatched as far as public record shows.
- The firmware does speak MQTT — but to Nexx's broker with shared
  hardcoded credentials, which is a cloud path (and the vulnerability),
  not a local one.

## Could it be liberated?
In principle the ESP-class hardware could be reflashed (no public custom
firmware project exists) or the MQTT target redirected — but that needs
firmware-level work on units with a known-hostile/unresponsive vendor and
no community toolchain. Not worth it versus ratgdo/OpenGarage/Meross
alternatives at the same price point.

## APK
Not fetched — the app's protocol is the cloud API; nothing local to recover.

## Rating
Dud (cloud-only; vendor unresponsive to CISA). Verified 2026-08-07.
