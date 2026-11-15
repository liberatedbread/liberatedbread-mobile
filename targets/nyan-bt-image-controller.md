# Nyan BT image controller (NYAN GEAR) — target spec starter

## Target metadata
- target_id: nyan-bt-image-controller
- app package_id(s): com.nyan.gear
- device class: controller for Wi-Fi/Bluetooth "device screens"
- transport(s): Wi-Fi + Bluetooth
- local-only viability: medium/high (local control likely; confirm if uploads require cloud)

## Known facts (public)
- App listing states it controls WiFi and Bluetooth device screens and supports text/pictures/animations/graffiti.

## Device discovery signals (hypotheses)
- BLE: device screen advertises; might share protocol family with LOY SPACE ecosystem.
- Wi-Fi: devices may host AP or use LAN.

## First experiments
1) Run ./scripts/detect_devices.sh; compare BLE device names and services against LOY SPACE devices.
2) Static APK scan:
   - compare endpoint domains and protocol code paths to LOY SPACE (if both reference the same backend/vendor libraries)
3) HCI snoop and/or Wi-Fi PCAP:
   - test image upload size limits and chunking behavior.

## Replacement app MVP
- connect device
- send image/text
- manage playlist locally

## References
- https://play.google.com/store/apps/details?id=com.nyan.gear
