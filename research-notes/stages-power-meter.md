# Stages Cycling Power Meters / Dash — Research Notes

## What it is
Stages Cycling: single-sided crank power meters (Stages Power L/LR, Shimano/SRAM/Campy
cranks), smart bikes (SB20), and the Dash GPS head unit. All BLE + ANT+.

## Why it is at-risk (near-death experience)
- Stages Cycling **ceased operations April 2024** and laid off all staff
  ([DC Rainmaker, 2024-04-26](https://www.dcrainmaker.com/2024/04/stages-cycling-messier.html),
  [BRAIN, 2024-04-24](https://www.bicycleretailer.com/industry-news/2024/04/24/stages-cycling-executives-join-giant-after-suit-and-apparent-shut-down)).
- Chapter 11 June 2024; Giant subsidiary Spia Cycling made a $20M stalking-horse bid
  ([BRAIN, 2024-06-27](https://www.bicycleretailer.com/industry-news/2024/06/27/giant-making-bid-buy-stages-cycling-bankruptcy),
  [road.cc, 2024-07-02](https://road.cc/content/news/giant-makes-bid-buy-stages-assets-20-million-309193)).
- Brand resumed trading under new ownership June 2025
  ([the5krunner, 2025-06-26](https://the5krunner.com/2025/06/26/stages-cycling-re-starts-trading/)),
  but the Stages Link cloud's continuity was uncertain through 2024–25, and Dash units
  depend on it for sync — classic at-risk profile.

## Local BLE feasibility — strong
- Power meters broadcast **standard BLE Cycling Power Service** — confirmed in app dex:
  `1818` CPS, `2a63` CP Measurement, `2a66` CP Control Point (zero offset!), plus FTMS
  `1826`, battery `180f`/`2a19`, DIS chars `2a24`–`2a29`, Nordic Secure DFU `fe59`.
- Any head unit/app (Garmin, Wahoo, Zwift, open-source) reads power locally — zero cloud.
- Zero-offset calibration is a standard CP Control Point write (`2a66`, opcode 0x0C) —
  documentable without any vendor involvement.
- Stages Cycling app (`com.stagescycling.stages`, final 4.1.2) handles firmware/zero
  offset; custom UUID families in dex: `7e0682c0`–`c3-7b8f-4645-ae2a-a88d4a42e9a6`,
  `0c46beaf`–`b1-9c22-48ff-ae0e-c6eae1a2f4e5`, `d445fe01/02-d139-9a5d-6707-1cc6a58b6303`
  (roles TBD — likely Dash/stages-bike specific).

## APK details (apkeep, apk-pure)
- Package: `com.stagescycling.stages`, version 4.1.2 (final), XAPK
- SHA-256 (xapk): `16df7e3893167c5511f15b6e200a031645f4e6f5aefa544611482430ccc1d36b`

## Open questions
- Dash head-unit local file sync path (USB mass storage vs dead cloud).
- Map custom services (SB20 smart bike control).
- Confirm zero-offset works app-free via generic BLE tools (expected: yes, standard 2a66).
