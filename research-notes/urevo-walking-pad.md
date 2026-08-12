# UREVO Walking Pads — Research Notes

## What it is
UREVO (UREVO WELLNESS US CO., LTD / urevo.com) sells a large range of
under-desk walking pads and 2-in-1 folding treadmills (SpaceWalk E3S/E4,
Strol 2E Pro, CyberPad, etc.). All "smart" models pair over BLE with the
**UREVO** app for control and workout tracking; pads also ship with a
physical remote. Vendor is active and launching new models (CyberPad,
2025-04; retail listings into 2026).

## Why it's at risk
- Not abandoned — a **cloud-at-risk / app-quality** case. The UREVO app sits
  at **2.7 stars (214 reviews, 50K+ downloads)** on Google Play as of
  2026-08-04, the classic pattern for vendor treadmill apps that users
  tolerate only because there is no alternative.
- App handles tracking/report sync; pads are also sold through
  Amazon/Walmart/Academy channels, so long-term app maintenance is not
  guaranteed. If the app is pulled, new owners lose speed programs and
  stats, though the IR remote keeps basic control.
- UREVO pads are KingSmith-adjacent in hardware class but there is no
  evidence they share the KingSmith WiLink/FTMS stack.

## Local BLE feasibility
- Confirmed BLE control path: retail listings and urevo.com state the app
  controls the treadmill "via Bluetooth" (Academy listing for E4S,
  2026-02-06; urevo.com app page).
- RESOLVED 2026-08-10: full protocol recovered from the APK's Dart AOT
  snapshot — see urevo-walking-pad.yaml. Pads speak either a UREVO custom
  "UR" protocol (service 0xFFF0, framed BluePackA commands: start/stop/
  pause/resume/set-speed all recovered) or standard FTMS (0x1826), per
  model. No pairing/auth on the control path.

## APK details
- **Package**: `com.urevo.app` ("UREVO")
- **Version**: 3.6.22 (versionCode 26042201), fetched 2026-08-04 via apkeep
  (APKPure XAPK)
- **XAPK SHA-256**: `c446b0200ffb27e7bed720293dab5ad4bbe79d9008635673b363239821a4ab63`
- Flutter app (correction: the earlier triage said "not Flutter" — wrong;
  UI/logic are Dart AOT in `config.armeabi_v7a.apk`'s `libapp.so`,
  Dart 3.4.3; the 7 DEX in the base APK are just the host + plugins, BLE
  via flutter_reactive_ble). Decompiled 2026-08-10 with a custom snapshot
  parser + capstone (workspace/static/urevo-walking-pad/analysis/).

## Open questions (updated 2026-08-10)
- BLE name prefix: `URTM*` match keys code-confirmed (URTM022 = SpaceWalk
  Lite); exact matcher semantics + whether UR pads advertise 0xFFF0 need
  one scan.
- FTMS vs custom: BOTH, per model (URTreadmill_* vs FTTreadmill_* classes,
  same numeric model codes). Resolved.
- Pairing token / handshake: none on the control path. Resolved.
- Stats sync: app-side + cloud; local control never touches the cloud.
- Remaining for one HCI snoop: speed scale factor (whole km/h vs 0.1 km/h),
  constant command payloads, u16 endianness in status frames, OTA char
  0xFEE2 role.

## Sources
- Play Store search result: UREVO app 2.7★, UREVO WELLNESS US CO., LTD (2026-08-04)
- urevo.com/pages/urevo-app and product pages (active 2025–2026)
- Academy E4S listing: "control your treadmills via Bluetooth" (2026-02-06)
- qdomyos-zwift src/devices listing (no UREVO driver; checked 2026-08-04)
