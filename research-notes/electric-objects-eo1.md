# Electric Objects EO1 / EO2 — Research Notes

## What it is
Electric Objects EO1 (2014) and EO2 (2016): 23" 1080p WiFi art frames running
Android, controlled by an iOS/Android app + cloud art subscription ("Art
Club"). The EO1 is effectively a wall-mounted Android tablet mainboard.

## Why it's abandoned (dated sources)
- The Verge (2017-06-27): Electric Objects shut down and sold the Art Club
  app to Giphy; founder Jake Levine's Medium post announced the shutdown.
- theharanguer.com (2023-07-11): eulogy — backend rot eventually stranded
  frames on the "Getting Art" dialog.

## Local rescue — confirmed community implementation
The frame's saving grace: it is a stock-ish Android device with USB host.

- **Physical access**: USB-OTG Y-cable gives keyboard+mouse. At the hung
  "Getting Art" dialog, `Win+B` opens the Android browser; swipe-down Settings
  → Security → enable Unknown Sources → sideload APKs.
- **spalt/EO1** (github.com/spalt/EO1, releases with ready APKs, 2023–2025):
  open-source replacement for the on-device Electric Objects app, installed as
  a home-screen replacement. Features: displays stills + MP4 video art from a
  Flickr account, slideshow interval, quiet hours, auto-brightness from the
  light sensor, manual brightness, media caching.
  - Caveat (repo README, 2025): Flickr stopped issuing API apps to free
    accounts; author is reworking the image-source backend. The app
    architecture (device app + local partner app) is unaffected in principle.
- **EO1 Partner App** (same repo, Android APK for the owner's phone): pushes
  images/video from the phone directly to the EO1 **over the LAN** ("assuming
  you are running on the same network as your EO1 device"), and sends
  brightness / quiet-hours / slideshow-interval / skip commands to the device
  the same way. This is the local-control channel: phone app → frame, no
  Electric Objects servers involved. Exact transport (port/format) is in the
  repo source under `app-partner/` — not yet transcribed here.
- Community art cache of EO-formatted MP4s: github.com/crushallhumans/eo1-iframe.

## What needs cloud
After the spalt/EO1 install: only the image *source* (currently Flickr API —
a personal API key, not an Electric Objects account). All control (push,
brightness, schedule) is LAN-local. First-time WiFi provisioning happens
on-device via keyboard/mouse, no account.

## APK
Not fetched via apkeep: the relevant app (spalt/EO1 + Partner) is open source
with published release APKs on GitHub; the dead vendor app has nothing left
to talk to.

## Open questions
1. Transcribe partner-app→device protocol from `app-partner/` source
   (port, message format) during spec work.
2. EO2 differences: EO2 shipped a different mainboard; spalt/EO1 targets EO1.
   EO2 local path unverified — likely Android sideload too, needs owner test.
3. ADB exposure on the EO1 USB port (would give a second local control path).

## Safety
None — display only.
