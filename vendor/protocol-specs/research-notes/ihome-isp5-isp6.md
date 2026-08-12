# iHome iSP5 / iSP6X Smart Plug — Research Notes

## What it is
iHome (SDI Technologies, alive) iSP5 (2015) and iSP6X (2017) Wi-Fi smart
plugs. Marketed around the iHome Control app + iHome cloud, with Wink,
SmartThings, Alexa, Google, Nest integrations — and, critically, **native
Apple HomeKit** support.

## Local protocol: HomeKit (HAP over IP) — confirmed
The reliable fully-local path is HomeKit, not the iHome app protocol:

- HomeKit pairing is a **local** ceremony using the 8-digit setup code
  printed on the device/in the manual — no iHome account or cloud involved.
- After pairing, control runs over the LAN via HAP (mDNS/Bonjour discovery,
  encrypted per-session). Works with any HAP controller: iOS Home app,
  Home Assistant `homekit_controller` (`iot_class: local_push`), or
  [jlhuerfanor/aiohomekit](https://github.com/Jc2k/aiohomekit)-class open
  implementations. A non-Apple controller (HA on a Pi) can pair directly
  with the setup code — no iPhone required.
- With WAN blocked, HomeKit control keeps working indefinitely.

## What is NOT local
- The iHome Control Android path depends on the iHome cloud; no documented
  plain local HTTP/UDP API exists for these models (community threads, e.g.
  openHAB 2019-01-17, never produced one — everyone falls back to HomeKit
  or IFTTT).
- The Wink integration is dead (Wink servers shut down 2024).
- Firmware updates require the iHome app + cloud; not needed for operation.

So: **local control = yes (HomeKit)**; vendor-app local API = no. iHome
account never required if onboarded straight into a HAP controller.

## Provisioning without iHome cloud
1. Plug in; wait for flashing green LED.
2. From a HAP controller (iOS Home or HA homekit_controller), start pairing
   and enter the printed setup code; supply Wi-Fi credentials during the
   HAP provisioning exchange (WAC/Bonjour).
3. Done — on/off (and, on iSP6X, no energy data over HAP; metering was only
   exposed via iHome cloud).

## APK
Not fetched — the iHome Control app is a cloud client; the documented local
path (HAP) is vendor-independent and needs no APK analysis.

## Safety
LOW. Mains relay (15 A, 1800 W per iSP5 manual). HAP is properly encrypted
and authenticated — the safest plug in this batch from a protocol standpoint.
