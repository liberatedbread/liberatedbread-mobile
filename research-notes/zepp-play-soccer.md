# Zepp Play Soccer — Research Notes

## What it is
Zepp Play Soccer (2016): a pair of small BLE pods clipped into calf sleeves that track
soccer stats — kicks, sprint distance, top speed, active time — synced to the
"Zepp Play Soccer" app. Same Zepp Labs lineage as the swing sensors.

## Why it is abandoned
Same story as the Zepp swing sensors: Huami acquired Zepp Labs (July 2018), pivoted the
brand to wearables, and the sport apps were dropped from the stores. App frozen at v1.6.5;
available only from APK mirrors. The Zepp sport-app cloud is reported offline (2026).
Sources: see `zepp-swing-sensors.md`.

## Local BLE feasibility
- Pods talk BLE directly to the phone; match stat aggregation is on-device.
- Same open question as the other Zepp apps: account login vs. local use.
- BLE UUID literals recovered from `com.zepp.soccer` dex (v1.6.5):
  - `7f400001-b5a3-f393-e0a9-e50e24dcca9e` — UART-style service (Nordic UART layout with
    a custom base, cf. Zepp swing sensors' use of stock `6e400001`)
  - `7f400002-b5a3-f393-e0a9-e50e24dcca9e` — UART RX/TX characteristic
  - `ed742075-c5a6-4475-907a-842f227df703` — purpose TBD
- App contains `zeppfirmwareupdate` machinery — DFU over BLE present.

## APK details (apkeep, apk-pure)
- Package: `com.zepp.soccer`, version 1.6.5
- SHA-256: `d8faceb8f2e9adb152efb7c96cf272e2024b953b680c007246e038ab6f172cbd`

## Open questions
- Full GATT table and stat frame format — needs jadx of the soccer BLE classes + HCI snoop.
- Whether both pods bond as separate peripherals and how the app distinguishes left/right.
- Login wall behavior of v1.6.5 with auth servers down.
