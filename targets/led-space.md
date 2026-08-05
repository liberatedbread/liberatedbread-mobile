# LED space (YSP-001 Wi-Fi backpack screen) — target spec starter

## Target metadata
- target_id: led-space
- app package_id(s): com.yj.led (LED space)
- iOS app id: 1431362600
- device class: Wi-Fi LED creative products — backpack screens, LED advertising vests, LED
  clothing, dynamic display bags
- transport(s): Wi-Fi (device AP); some hardware in the family is Bluetooth instead
- local-only viability: high if the AP-mode path is complete — the app's own copy describes it
  as controlling "the WiFi device screen"

## Why this target matters
LED space is already listed in `targets/targets.csv` but has never had a starter spec. It is the
Wi-Fi sibling to the BLE-heavy LED panel targets in this repo, and it is a strong candidate to
collapse into an **already-solved** protocol (see below) rather than needing fresh work.

## Known facts (public)
- App copy: "LED space is a creative APP product that controls the WiFi device screen. You can
  create colorful text, beautiful pictures, cool animation, fun graffiti and other programs
  through the APP." Built-in material library, 13 languages, multi-specification screen support.
- Marketed for LED backpacks, advertising vests, LED clothing and dynamic bags.
- Product listings name the panel **YSP-001**; a given backpack may ship the Wi-Fi or the
  Bluetooth variant of the same board.

## Strong hypothesis: this is the popled.cn / LOY SPACE platform
The `YS` naming (`YSP-001`) matches the discovery signals already documented for the
[AUTOBABA LED Backpack](../docs/devices/autobaba-led-backpack.md) / LOY SPACE platform:

- BLE name prefix `YS` / `TL`
- Wi-Fi SSID containing `YS`, AP mode, default password `12345678`
- UDP port 9090, broadcast discovery to `192.168.4.255`, device answers from `192.168.4.1`
- `aa 55` framed TLV packets carrying JSON commands (`{power:…}`, `{light:…}`, `{pgm_play:…}`)
- 24-bit uncompressed BMP image payloads

**Validate this before doing anything else.** If it holds, LED space is a third app on an
already-documented protocol and needs no new reverse engineering — only a spec cross-reference.

## Device discovery signals
- Wi-Fi:
  - SSID patterns: containing `YS` (verify), AP mode
  - default gateway: `192.168.4.1` (ESP-style AP) — verify
  - UDP discovery: port 9090, broadcast `192.168.4.255`
- BLE (for the Bluetooth variant of the same hardware):
  - advertised name prefix: `YS` or `TL`
  - service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`

## First experiments
1) Power the panel, list nearby SSIDs, and join the device AP. Confirm gateway and whether the
   default password `12345678` applies.
2) Send the documented LOY SPACE discovery broadcast to `192.168.4.255:9090`:
   `aa 55 ff ff 08 00 01 00 c1 03 0a 00 d4 03` — a reply from `192.168.4.1` confirms the
   hypothesis outright.
3) If it replies: run `{get:"dev_info"}` and compare the response against the AUTOBABA spec.
   Fold LED space into that device doc as an additional app.
4) If it does not: tcpdump a full session (connect → upload one image) and treat as a new
   protocol.
5) Static-analyse the APK for `popled.cn` / `wxbtapp-cdn` endpoints — their presence is a second
   independent confirmation of the platform.

## Threat model + guardrails
- Owned devices only. Joining a device AP puts the phone on the panel's network; do not probe
  beyond the device address.
- Do not commit any vendor backend credentials (`app_key` and similar) recovered from the APK —
  see `docs/CLEANROOM_RULES.md`.

## Replacement app MVP
- join / discover the panel without an account
- report geometry from the device
- brightness, power, program select
- upload a still image and an animation
- keep working with no internet connection

## References
- https://play.google.com/store/apps/details?id=com.yj.led
- https://apps.apple.com/us/app/led-space/id1431362600
- ../docs/devices/autobaba-led-backpack.md
