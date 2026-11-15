# AUTOBABA LED backpack — target spec starter

## Target metadata
- target_id: autobaba-led-backpack
- controlling app package_id(s): com.yskd.loywf (LOY SPACE)
- device class: programmable LED backpack screen
- transport(s): Wi-Fi + Bluetooth (per LOY SPACE listing; verify which is used in practice)
- local-only viability: high if BLE-only control exists; medium if Wi-Fi requires cloud

## Known facts (public)
- LOY SPACE app describes controlling WiFi and Bluetooth device screens.
- Similar LED backpacks documented online often warn: connect inside the app (Bluetooth logo) rather than via system-level pairing.

## Device discovery signals (hypotheses)
- BLE advertised name patterns: likely generic ("Backpack", "LED", "LOY", random) — discover via scans
- Wi-Fi SSID patterns: possible custom AP mode for uploads (64x64 animation payloads)
- Potential shared ecosystem with NYAN GEAR class apps

## First experiments
1) Run ./scripts/detect_devices.sh near the backpack with it powered on.
2) Determine transport:
   - If BLE-only: HCI snoop connect + upload a small image.
   - If Wi-Fi: connect to backpack SSID and tcpdump the session.
3) Static APK scan (LOY SPACE):
   - search for popled.cn endpoints
   - search for payload chunk sizes, compression, and any CRC routines
4) Identify the minimum control set:
   - set brightness/animation
   - push bitmap/gif frames
   - read device status (battery?)

## Replacement app MVP
- connect + send pixels reliably
- no forced account requirement for offline uploads

## References
- https://play.google.com/store/apps/details?id=com.yskd.loywf
