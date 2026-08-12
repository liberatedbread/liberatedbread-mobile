# Nespresso Prodigio — Research Notes

## What it is
Nespresso Prodigio (launched 2016-03, Nestlé press release): the first
Bluetooth-connected Nespresso machine. BLE ("Bluetooth Smart") link to the
Nespresso app for remote/scheduled brew, maintenance alerts (descale, water,
capsule container) and capsule stock management. Two SKUs: Prodigio and
Prodigio & Milk. The machine brews fine standalone via its three buttons — BLE
adds remote start, scheduling and status.

## Why it's at-risk / effectively abandoned
- Product line **discontinued 2020** (whichnespresso.com: "Nespresso
  discontinued the Prodigio line in 2020"); Nespresso never shipped another
  Bluetooth Original-line machine.
- Nestlé is alive, so this is *product abandonment*, not company death — but
  the BLE feature depends on app support that Nespresso has no obligation to
  keep. Current Nespresso app versions have dropped Prodigio-era pairing
  (unverified — see open questions).

## Local BLE feasibility
Plausible: 2016-era "Bluetooth Smart" design means the phone talks GATT
directly to the machine; brew/schedule commands are simple actuations. No
community RE found (2026-08) — greenfield. Because the machine is fully
functional without the app, the stakes (and RE risk) are low.

## APK
- Legacy pairing lived in the old "Nespresso" Android app (pre-2020 redesign).
  Current app (`com.nespresso.aaa`) fetch via apkeep/apk-pure **failed**
  2026-08-03 (regional/catalog issue); legacy builds not on apk-pure.
- **APK treated as unfetchable for now** — try google-play source with
  credentials, or APKCombo archive of 2017-2019 "Nespresso" builds.

## Open questions
1. Does the current Nespresso app still pair a Prodigio? (Determines urgency.)
2. Advertising name / GATT services — needs a unit or the legacy APK.
3. Does remote brew require capsule-present + water interlocks (sane default:
   yes), and are they enforced on-device?

## Safety
MEDIUM-LOW — hot water/coffee dispensing; keep on-device interlocks, never
force a remote brew without them.
