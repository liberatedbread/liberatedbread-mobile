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
- No public protocol RE found. qdomyos-zwift has NO UREVO driver (checked
  src/devices, 148 entries). Some UREVO models may expose standard FTMS —
  hypothesis only; several 2024+ Chinese pads do.
- Verdict: feasible, greenfield. APK is native and fetched, so UUIDs and
  command frames are recoverable with a focused jadx session.

## APK details
- **Package**: `com.urevo.app` ("UREVO")
- **Version**: 3.6.22 (versionCode 26042201), fetched 2026-08-04 via apkeep
  (APKPure XAPK)
- **XAPK SHA-256**: `c446b0200ffb27e7bed720293dab5ad4bbe79d9008635673b363239821a4ab63`
- Native app (7 DEX in base APK; not Flutter). Triage string pass did not
  surface full 128-bit UUIDs — likely built from 16-bit shorts at runtime or
  obfuscated. Needs a real jadx pass (~1 h) or HCI snoop.

## Open questions
- BLE name prefix and service UUIDs (scan or jadx).
- FTMS-standard vs custom protocol (decides whether QZ/generic FTMS clients
  already work).
- Any pairing token / handshake gating speed commands.
- Whether stats sync is purely app-side (then cloud loss costs nothing
  locally).

## Sources
- Play Store search result: UREVO app 2.7★, UREVO WELLNESS US CO., LTD (2026-08-04)
- urevo.com/pages/urevo-app and product pages (active 2025–2026)
- Academy E4S listing: "control your treadmills via Bluetooth" (2026-02-06)
- qdomyos-zwift src/devices listing (no UREVO driver; checked 2026-08-04)
