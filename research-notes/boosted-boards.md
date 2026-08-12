# Boosted Boards (all gens + Boosted Rev) — BLE Protocol Research Notes

## What it is
Electric skateboards (Boosted Single/Dual/Dual+ V1–V3, Mini S/X, Plus, Stealth) and the
Boosted Rev e-scooter, by Boosted Inc. Board control while riding is via a handheld
BLE remote; the phone app handles pairing, ride modes, firmware updates, odometer/range,
and cloud ride logging.

## Why it's abandoned
- Boosted Inc. laid off staff and entered liquidation in **March–May 2020**; brand assets
  later acquired by "Boosted USA" (a reseller that explicitly disclaims the original
  company: "Boosted went bankrupt"). [boostedusa.com FAQ](https://boostedusa.com/pages/faq)
- Community-maintained successor FAQ: "The official Boosted app has slowly been losing
  functionality as Boosted's servers go offline. First, it lost the ability to update
  boards' firmware." [foreverboosted.co FAQ, 2020](https://foreverboosted.co/faq)
- The Play Store listing is gone; the APK survives only on mirrors.

## Local BLE feasibility — HIGH
- The app talks to the board over BLE directly; riding never requires the app at all
  (handheld remote). The app's board-facing functions (mode, name, units, firmware)
  are all local GATT operations. Cloud features (account, ride sync, leaderboard,
  firmware hosting) are dead, but none are needed for control.
- Decompiled APK confirms scan-by-service-UUID discovery: V2 boards advertise
  `7DC55A86-C61F-11E5-9912-BA0BE0483C18`, V1 boards advertise
  `DA2B84F1-6279-48DE-BDC0-AFBEA0226079` (`com/boostedboards/android/ble/f.java`).

## BLE map (recovered from DEX, `com.boostedboards.android.ble`)
### Board service V2/V3 — `7DC55A86-C61F-11E5-9912-BA0BE0483C18` family
Characteristic enum (`ble/h0/g.java`, name → UUID, notify flag):
| Characteristic | UUID | Notify |
|---|---|---|
| VEHICLE_ID / VEHICLE_NAME | 7DC5BB39-C61F-11E5-9912-BA0BE0483C18 | n |
| VEHICLE_MODEL | 7DC59643-C61F-11E5-9912-BA0BE0483C18 | n |
| VEHICLE_MODES_COUNT | 7DC55DEC-C61F-11E5-9912-BA0BE0483C18 | n |
| VEHICLE_MODE | 7DC55F22-C61F-11E5-9912-BA0BE0483C18 | y |
| VEHICLE_ODOMETER | 7DC56594-C61F-11E5-9912-BA0BE0483C18 | y |
| VEHICLE_SPEED | 7DC56B34-C61F-11E5-9912-BA0BE0483C18 | y |
| VEHICLE_POWER | 7DC56BFC-C61F-11E5-9912-BA0BE0483C18 | n |
| VEHICLE_UNITS | 7DC5C19D-C61F-11E5-9912-BA0BE0483C18 | n |
| VEHICLE_MD_SERIAL | 7DC5C201-C61F-11E5-9912-BA0BE0483C18 | n |
| VEHICLE_MD_FW_VERSION | 7DC5C202-C61F-11E5-9912-BA0BE0483C18 | n |
| BATTERY_ID | 65A8F834-C61F-11E5-9912-BA0BE0483C18 | n |
| BATTERY_FW | 65A8F833-C61F-11E5-9912-BA0BE0483C18 | n |
| BATTERY_REMAINING | 65A8EEAE-C61F-11E5-9912-BA0BE0483C18 | y |
| BATTERY_CAPACITY | 65A8F3C2-C61F-11E5-9912-BA0BE0483C18 | n |
| BATTERY_CHARGING | 65A8F5D4-C61F-11E5-9912-BA0BE0483C18 | y |
| LIGHTS_DEFAULT_MODE | EA32B761-D410-42E2-848A-1218201468FC | n |
| LIGHTS_STATUS | EA32DCAC-D410-42E2-848A-1218201468FC | y |
| LIGHTS_BRIGHTNESS | EA326B96-D410-42E2-848A-1218201468FC | n |
| BRAKE_LIGHTS_PATTERN | EA324D8C-D410-42E2-848A-1218201468FC | n |
| SERIAL_CMD | 58856524-0065-11E6-8D22-5E5517507C66 | n |
| SERIAL_AUTH | 58856525-0065-11E6-8D22-5E5517507C66 | y |
Plus standard DIS: MOTORDRIVER_FW_VERSION on `00002a26`, SCOOTER_SERIAL on `00002a25`.
Note: the VEHICLE_ID/VEHICLE_NAME pair share one UUID in the enum — verify on hardware.

### V1 board path — `ble/e0/a.java`
Service `DA2B84F1-6279-48DE-BDC0-AFBEA0226079`; characteristics
`99564A02-DC01-4D3C-B04E-3BB1EF0571B2`, `A87988B9-694C-479C-900E-95DFA6C00A24`,
`BF03260C-7205-4C25-AF43-93B1C299D159`, `18CDA784-4BD3-4370-85BB-BFED91EC86AF`,
plus `FDD6B4D3-046D-4330-BDEC-1FD0C90CB43B` (role TBD — possibly Beams accessory).

## Prior community RE (gold)
- [beambreak.org](https://beambreak.org/) / [axkrysl47/BoostedBreak](https://github.com/axkrysl47/BoostedBreak):
  full-board RE — SR↔ESC CAN documented with DBC file, battery emulator PoC, accessory
  port pinout, Web Bluetooth V2+ remote tester.
- [tejasbhakta.com/boosted-board](https://tejasbhakta.com/boosted-board): remote↔board BLE
  protocol writeup ("relatively simple" protocol).
- [johnathanchiu/boosted-project](https://github.com/johnathanchiu/boosted-project): ESP32
  replication of the remote↔board pairing protocol.
- [shwin.co v1 progress dump](https://shwin.co/blog/reverse-engineering-the-boosted-board-v1).

## APK provenance
- Package `com.boostedboards.android` ("Boosted Boards", last release **1.4.5**, 2019-12-04)
- apkeep (apk-pure mirror), APK 9,482,103 bytes
- SHA-256: `2c0deabe7ce1a5ea66500112d63513a71e52d0b361619e9bc528cecb0daaefdd`
- Kotlin + RxAndroidBle2, unobfuscated package names under `com.boostedboards.android.ble`
- Cloud remnants: `boostedApi` with facebookLogin/googleLogin/getInbox/createRide — all dead.

## Open questions
- Remote↔board link: pairing crypto and throttle frame format (beambreak has this
  partially; ESP32 clone proves it's reproducible).
- SERIAL_CMD/SERIAL_AUTH: is there a challenge-response before mode writes on late firmware?
- Boosted Rev scooter: same V2 service family? (SCOOTER_SERIAL char suggests yes.)

## Safety
Vehicle (20+ mph electric skateboard). Mode/speed-limit writes are safety-relevant.
safety_class: HIGH.
