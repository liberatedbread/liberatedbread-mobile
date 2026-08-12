# PAX (allowed) — target spec starter

## Target metadata
- target_id: pax-vape
- app package_id(s): com.pax.app
- device class: vaporizer
- transport(s): Bluetooth (likely BLE)
- local-only viability: medium (expected local BLE control; verify whether any features require account/cloud)

## Known facts (public)
- Vendor describes "The PAX App" as compatible with PAX 3 and Era Pro and lists features like finding devices and controlling temperature.
- Vendor provides a web app and references an Android app link (Play listing may be unavailable).

## Device discovery signals (hypotheses)
- BLE advertised name patterns: "PAX", "ERA", or model-specific strings (unknown until scanned)
- Service UUIDs: unknown (discover via HCI snoop + GATT enumeration)

## First experiments
1) Run ./scripts/detect_devices.sh with the device powered on and near the scanner.
2) Enable Android Bluetooth HCI snoop logging, then:
   - open the app
   - connect to device
   - perform ONE action (e.g., change temperature)
   - pull /sdcard/btsnoop_hci.log with ./scripts/detect_devices.sh or adb pull.
3) Static APK scan:
   - search for UUID literals (0000xxxx-0000-1000-8000-00805f9b34fb and 128-bit UUIDs)
   - search for "bluetooth", "gatt", "characteristic", "pax", "era"
4) Determine whether bonding is required or if it’s a “no-bond GATT write” model.

## Replacement app MVP
- connect/unlock
- read device status (battery/temp/mode)
- set temperature / session mode
- safety guard: do not enable anything beyond normal manufacturer ranges

## References
- https://www.pax.com/discover/mobile-app
- (If accessible) https://play.google.com/store/apps/details?id=com.pax.app
