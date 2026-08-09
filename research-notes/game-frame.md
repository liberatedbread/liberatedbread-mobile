# LEDSEQ Game Frame (Wi-Fi Adapter) — Research Notes

## What it is
Game Frame by LEDSEQ (Jeremy Williams): 16×16 = 256-pixel LED art display
for pixel-art animations (2014 Kickstarter). The **Wi-Fi Adapter** (2016)
swaps the stock Teensy LC controller for a Particle Photon carrier, adding
WiFi. LEDSEQ still operates (ledseq.com docs live as of 2026-08-07). Firmware
source was published by LEDSEQ (docs invite users to "add to the source
code").

## Local interface — confirmed (vendor-documented)
From the official Wi-Fi Adapter documentation (ledseq.com, 2016-10-23):

- On boot the display **scrolls its IP address**; browsing to
  `http://<ip>/` serves a local web page that "controls every aspect of
  Game Frame" — power, brightness, playback mode, animation selection
  (Play/Alert by folder name), clock faces, solid-color fill, timezone.
- Vendor caveat: "the web server is very lightweight and kind of fragile" —
  restart if it wedges.
- The raw HTTP routes behind that page are not separately documented, but the
  firmware source is available, so endpoint transcription is straightforward.
- WiFi credentials live in a plain-text file on the microSD:
  `/00system/wifi/wifi.ini` — provisioning is a file edit, no account.

## Command model (from vendor docs)
Functions: `Command` (catch-all), `Next`, `Power` (on/off/toggle), `Play
<folder>`, `Alert <folder>` (one-shot overlay, resumes after), `Brightness
0-7`, `Color <#hex|random>`, plus `clockface 1-5`, `timezone`, `playback 0-2`,
`display 0-2` (Gallery/Clock/Effects), `cycle 1-8`, `reboot`.
Vendor documents calling these via the Particle cloud REST API — but the same
functions back the local web page; the local invocation path is what spec
work should transcribe from firmware source.

## Cloud dependency
- Local web UI + SD-card content: none. Fully air-gappable after flashing.
- IFTTT/"functions over internet" path uses the Particle cloud — optional;
  the Photon can run without claiming to a Particle account in the local-only
  flow (setup per Particle "Connect Your Photon" can be done via USB/serial).

## Existing implementations
- savvasdalkitsis/gameframe (GitHub, 2017) — third-party Android control app
  for Game Frame Wi-Fi (talks to the device; good source for the local
  routes).
- Vendor firmware source + community forks on GitHub.

## APK
Vendor has no Android app; third-party app above is open source. Not fetched.

## Open questions
1. Transcribe exact local HTTP routes from firmware source (Particle `TCPServer`
   handler) during spec work.
2. Particle cloud-claim removal: document the exact no-cloud bring-up for a
   used Wi-Fi Adapter.
3. Is the current-production Game Frame still Photon-based?
