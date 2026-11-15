# Tidbyt Gen1/Gen2 — Local Control Research Notes

## What it is
Tidbyt: retro 64×32 LED pixel display (ESP32) showing rotating "apps"
(clock, transit, weather, custom). Company (Tidbyt Inc., Brooklyn) alive and
selling Gen2 as of 2026-08-07.

## Stock architecture — cloud by design
Stock firmware is a pull client: the device fetches rendered WebP frames from
Tidbyt's backend; the official "push" API (`api.tidbyt.com`, device ID + API
key from the mobile app) also terminates at Tidbyt's cloud — the phone/server
never talks to the device directly. **There is no official local API.**

## Local path — confirmed community implementation (Tronbyt)
Tronbyt fully liberates the hardware:

- **tronbyt/server** (github.com/tronbyt/server, formerly tavdog/tronbyt-server):
  self-hosted Go server (Docker Compose, Homebrew, or bare metal). Web UI to
  manage devices/apps, renders apps (pixlet-compatible Starlark) to WebP,
  serves them over plain HTTP on the LAN. Explicit goal: keep displays alive
  after a Tidbyt cloud shutdown; also unlocks apps Tidbyt blocked server-side.
- **tronbyt/firmware** (github.com/tronbyt/firmware, formerly
  tavdog/tronbyt-firmware-http): community ESP32 firmware flashed via USB
  (PlatformIO). WiFi credentials + server URL configured at flash/provisioning
  time; device then pulls frames from the LAN server on its app-cycle interval.
- Supports Tidbyt Gen1 and Gen2 plus custom ESP32 matrix hardware.
- Coverage: Hackaday.io project log (2025-03-28) "Saving the Tidbyt from the
  inevitable cloud shutdown".

So the local protocol is a deliberately simple **HTTP pull**: device GETs a
WebP (and a brightness/cycle cadence) from a configured URL. That URL can be
*any* LAN HTTP server — a minimal local controller can be a static file
server regenerating a WebP; Tronbyt Server is the batteries-included option.

## What needs cloud
With Tronbyt: nothing. Initial flash needs a USB host computer, no account.
Stock firmware: everything (pairing, apps, push) needs Tidbyt cloud.

## APK
Companion app is only used for stock cloud pairing — irrelevant to the local
path. Not fetched.

## Open questions
1. Exact request headers/device-identification the Tronbyt firmware sends
   (transcribe from tronbyt/firmware source during spec work).
2. OTA/update story for the community firmware.
3. Stock-firmware local push feasibility (TLS-pinned to Tidbyt backend —
   assumed no; not investigated deeply since Tronbyt exists).
