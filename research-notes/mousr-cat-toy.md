# Petronics Mousr — Research Notes

Robotic cat toy ("smart mouse") with BLE app control. Company dead; hardware and app fully local over BLE.

## What it is
- Mousr: app-enabled robotic cat toy by Petronics Inc. (Champaign, IL). Kickstarter 2014, shipped ~2018.
- Autonomous play modes (Open Wander, Wall Hugger, Stationary) plus manual "drive it yourself" mode from the phone app.
- Sensors: forward distance sensor, cat proximity sensor, orientation/IMU; swappable tails; charging dock; speaker.
- Kickstarter FAQ confirms Bluetooth Low Energy as the control link ([Kickstarter FAQ](https://www.kickstarter.com/projects/525985345/mousr-the-robotic-mouse-that-plays-with-your-cat/faqs)).

## Why it's abandoned (dated sources)
- Petronics stopped production of Mousr — reported Sept 2020 ([consumeroutlook.info review update](https://consumeroutlook.info/2018/11/06/mousr/), 2018-11-06, updated 2020-09).
- `petronics.io` no longer resolves in DNS (verified 2026-08-03). App support email `support@petronics.io` is therefore dead.
- Android app `com.petronics.mousr` is delisted from Google Play; only mirrors (APKPure) still carry it (verified 2026-08-03).

## Local BLE feasibility — STRONG
- Control path is phone ↔ toy over BLE only. No Wi-Fi on the device; reviews explicitly note remote play is impossible because "it's bluetooth only" (Amazon.ae review).
- No account/login flow found in the app; network access appears used only for firmware-update checks and web links (strings: `netprob`, `checknetwork`, petronics.io URLs).
- The app bundles Nordic DFU firmware images (`assets/fw_v0.0-44-gb24db8f.zip`, `fw_v0.1-1-gd4f09ac.zip`, `fw_v1.1-4-75e5717.zip`, `sd_bl12.zip`) — firmware payloads are recoverable for protocol study without any hardware.
- No prior community RE found (searched GitHub/forums 2026-08-03). Greenfield but the UART service is standard.

## APK provenance
- **Package**: `com.petronics.mousr` ("Mousr")
- **Source**: apkeep, apk-pure. Versions available: 0.9.1 … 1.0.7; downloaded latest.
- **SHA-256**: `ed89a8f181a33eccfec7e52db68614658ff9572855ef05e28521f8a8eef8e38d` (33 MB bare APK)
- **App version**: embedded `assets/ver.txt` = `1.0.6(6ce8c10)`
- **Framework**: Unity (C# metadata in `assets/bin/Data/Managed/Metadata/global-metadata.dat`) + a Unity BLE plugin; Nordic DFU library for firmware updates.
- Play listing referenced in bundled user guide: `play.google.com/store/apps/details?id=com.petronics.mousr` (now dead).

## BLE UUIDs (from Unity metadata)
| UUID | Role |
|------|------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART service (primary control channel, expected) |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | UART RX (write to Mousr) |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | UART TX (notify from Mousr) |
| `8ec90001-f315-4f60-9fb8-838830daea50` | Laird BL600 Virtual Serial Port service (legacy/alternate) |
| `8ec90002-f315-4f60-9fb8-838830daea50` | Laird VSP characteristic |
| `0000fe59-0000-1000-8000-00805f9b34fb` | Nordic Secure DFU (buttonless) service |
| `ee799f41-cfa5-550b-bf2c-344747c1c668` | Unidentified custom UUID (possibly hash artifact — verify) |

- Hardware hypothesis: Laird BL600-series BLE module (`sd_bl12.zip` = SoftDevice image; `BL12` naming).
- Advertising name: user-settable in-app ("Give Mousr a name"); factory default likely `Mousr` (unverified).

## What needs cloud
- Nothing for operation. Firmware update check pings petronics.io (dead) — DFU can still be driven manually with the bundled zip.

## Open questions
1. UART command byte format for drive/mode/sound/tail commands — needs HCI snoop or il2cpp decompile (`global-metadata.dat` + `libil2cpp.so`).
2. Is the Nordic UART the live control channel, or the Laird VSP? Both appear; determine which the app actually subscribes to.
3. Whether the app enforces any first-run network check (appears not, but untested on-device).
