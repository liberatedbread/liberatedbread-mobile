# Narwal Flow / Freo — Local WebSocket Research Notes

## What it is
Narwal (Yunjing Intelligence, Dongguan) robot vacuum-mops: Freo line,
Freo Z10 Ultra/Pro, X10 Pro, and the roller-mop Flow (AX12, 2025) / Flow 2.
Robots run OpenWrt (Tina) on Allwinner MR813-class SoCs (robotinfo.dev
hardware DB). Vendor app is cloud-first, but the robot exposes a local
WebSocket API.

## Local protocol (community-confirmed, 2026)
- The robot serves WebSocket on TCP 9002 on the LAN.
- Auth/encryption: per-model "product key" (AES) embedded in the vendor
  app; community extracted keys via APK analysis for the AX/BX/CX/X model
  families (hassbian.com thread, 2026-04-24).
- Reference implementation: sjmotew/NarwalIntegration (HACS custom
  integration, MIT, 2026-02) — fully local, no cloud, no account: start /
  stop / dock / room cleaning (`vacuum.clean_area`), map display, sensor
  state.
- Confirmed working models (integration README, 2026-02 + community):
  Flow (AX12), Flow 2, Freo Z10 Ultra (CX4), Freo Z10 Pro/Turbo (AX26),
  Freo X10 Pro (AX15), plus 逍遥002 Max (CX7) confirmed on the hassbian
  thread; J4/J5 families have APK-sourced keys (untested).
- Firmware quirks documented: Flow firmware v01.07.22+ requires a loaded
  map before `vacuum.start` works (integration issue #36).

## Model-level dud
**Freo X Ultra (AX18) exposes no local WebSocket — cloud-only.** Do not
buy it for local control (hassbian table marks it ☁️).

## What needs cloud
Initial Wi-Fi provisioning goes through the Narwal app (vendor account).
After provisioning, the integration path is fully local; WAN can be
blocked. No evidence that the product key rotates.

## APK
- Narwal app: package ID could not be confirmed on the Google Play mirror;
  apkeep attempts (com.narwal.freo / .app / .robot, com.yunjing.smart) all
  failed 2026-08-07. Community already extracted product keys from the
  Android APK, so the file exists in circulation (Chinese-market package);
  record as fetchable-via-other-means.

## Open questions
1. Product-key scope: one key per model family or per firmware? (integration
   issues suggest family-level)
2. J4/J5 on-the-wire validation (keys exist, no confirmed user reports).
3. WebSocket message schema belongs in the spec — source is the
   NarwalIntegration repo.
