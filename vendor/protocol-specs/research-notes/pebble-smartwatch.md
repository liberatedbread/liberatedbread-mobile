# Pebble Smartwatch Family — Research Notes

The flagship "liberated device" case: company dead, cloud dead, but the watch is
fully drivable locally over Bluetooth Classic SPP, and the protocol was always
public.

## Device / Company Status
- **Products**: Pebble Classic/Steel (2013), Time/Time Steel/Time Round (2015),
  Pebble 2 (2016). Pebble Technology Corp.
- **Company dead**: Pebble confirmed shutdown 2016-12-07; software/IP sold to
  Fitbit ([TechCrunch](https://techcrunch.com/2016/12/07/pebble-confirms-its-shutting-down-devs-and-software-going-to-fitbit/)).
  Fitbit ran the appstore/web services ~1.5 years, then killed them June 2018
  ([ericmigi.com timeline](https://ericmigi.com/blog/pebble-rebble-and-a-path-forward)).
- **Community takeover**: Rebble (rebble.io) re-implements the web services
  (store, weather, dictation, timeline pins). Account optional — see below.
- **2025+ coda**: PebbleOS was open-sourced by Google and Eric Migicovsky's new
  company (Core Devices) ships new hardware running it; old watches benefit from
  the same revived toolchain.

## Local Feasibility: CONFIRMED
Core watch functions are 100% local over Bluetooth Classic:
- Android pairing uses **SPP/RFCOMM with the standard SPP UUID
  `00001101-0000-1000-8000-00805F9B34FB`** (found in the last Pebble app at
  `com/getpebble/android/bluetooth/j/b.java:18`, `createRfcommSocketToServiceRecord`).
  Time-series watches additionally expose BLE GATT services (LE pairing +
  PPoGATT on later firmware), but classic SPP remains the primary data path on Android.
- **Gadgetbridge** ([codeberg.org/Freeyourgadget/Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge))
  is a cloudless Pebble companion: notifications, music control, weather (via
  local providers), watchface/app install (.pbw sideload), firmware flash —
  no Rebble account, no cloud at all.
- Pebble **protocol is fully documented** (endpoints: notification, music, time,
  app message, blobdb, screenshot, ping...): developer.rebble.io hosts the old
  official docs; libpebble/libpebble2 and PebbleKit sources are public.
  Desktop: `pebble` CLI / libpebble2 can drive a watch from a PC over SPP.

## APK Provenance
- **Package**: `com.getpebble.android.basalt` (final Pebble app line, v4.x)
- **Source**: apkeep, APKPure. 26 versions listed; fetched latest
  `4.4.3-1406-65190dddb-endframe` ("endframe" = final release train).
- **SHA-256**: `7be78e833a65e2bd0db1d40c3e1063bbcf64a8068990b5a26fecfd24b2daaabc` (26,646,630 bytes)
- Stock app is usable but pushes Pebble/Rebble account login; Gadgetbridge is the
  recommended fully-local path. Rebble also ships its own app (Cobble, open source).

## Open Questions
- PPoGATT (BLE) service details on latest firmware — only relevant for iOS-style
  stacks; SPP covers Android/PC.
- Old Pebble firmware images are hosted by Rebble; verify mirror hashes if
  archiving flashing instructions.

## Sources
- techcrunch.com/2016/12/07/pebble-confirms-its-shutting-down-devs-and-software-going-to-fitbit/
- ericmigi.com/blog/pebble-rebble-and-a-path-forward (2025-11-18)
- developer.rebble.io (protocol docs, pebble-tool)
- codeberg.org/Freeyourgadget/Gadgetbridge
- Static pass: jadx on com.getpebble.android.basalt 4.4.3 (workspace/static/pebble)
