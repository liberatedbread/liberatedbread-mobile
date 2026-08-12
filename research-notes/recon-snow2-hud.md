# Recon Instruments Snow2 HUD — Research Notes

## What it is
- **Snow2**: a modular Android-powered heads-up display (2013, $399) that clips into ski/snowboard goggles (Oakley Airwave, Zeal Transcend, Smith, Scott, etc.). GPS, 9-axis IMU, altimeter; displays speed/vertical/distance/maps direct-to-eye. Runs ReconOS (Android 4.1 Jelly Bean) — it is itself a full Android computer with WiFi, BT, USB, and ADB.
  - [LinuxGizmos 2013-11-19](https://linuxgizmos.com/hud-enabled-ski-goggles-run-android/), [Snowboard Mag 2013-11-19](https://snowboardmag.com/stories/recon-debuts-snow2-4th-generation-hud)
- Companion phone app: **Recon Engage** (`com.reconinstruments.jetandroid` on Android) for notifications, music control, friend tracking, trip sync.

## Why it's abandoned
- Recon Instruments acquired by Intel (2015); **Intel discontinued the Recon line in 2017** ([LinuxGizmos 2017-06-28](https://linuxgizmos.com/intel-pulls-the-plug-on-its-joule-edison-and-galileo-boards/)). ReconInstruments.com is gone; engage.reconinstruments.com backend dead.
- Recon Engage returns **404** on Play (verified 2026-08-04).

## Local feasibility — good, but note the transport
- **Phone↔HUD link is Bluetooth Classic SPP, NOT BLE.** `BTTransportManager.java` opens three RFCOMM channels with vendor UUIDs:
  - `B29E4260-9D8A-11E2-9E96-0800200C9A66`
  - `B29E4261-9D8A-11E2-9E96-0800200C9A66`
  - `B29E4262-9D8A-11E2-9E96-0800200C9A66`
  (three `BTConnectThread`/`BTConnectedThread` pairs — likely control / data / aux channels.) No `BluetoothGatt` anywhere in the app. BLE on the HUD exists for ANT+-bridge/sensors, but the phone link is SPP.
- **The stronger liberation path is the device itself**: Snow2 runs rootable Android 4.1.2 with ADB; owners already sideload XCSoar/XCTrack for paragliding ([paraglidingforum.com 2016-11-20](https://www.paraglidingforum.com/viewtopic.php?p=p506464)) and there's an active XDA thread ([xdaforums Recon Jet/Snow basic info](https://xdaforums.com/t/recon-jet-basic-info.3086703/page-4)).
- Prior community RE: [github.com/stevenhgs/rib-to-gpx-file-converter](https://github.com/stevenhgs/rib-to-gpx-file-converter) — decodes the proprietary `.rib` activity files the cloud used to convert (Snow2 and Zeal Transcend tested).

## What needs cloud (dead)
- Firmware updates (ReconOS updates came via engage.reconinstruments.com), `.rib`→GPX conversion service (community tool replaces it), friend live-tracking, trip sync to Engage web.

## APK Provenance
- **Package**: `com.reconinstruments.jetandroid` ("Recon Engage"; shared app for Jet + Snow2)
- **Source**: apkeep, `apk-pure`
- **APK SHA-256**: `7919719782e3a16074a1f3db774a66f5fe7cffb0943faf1093ee097432637a8c` (8.7 MB)
- **Version**: 4.4.4.203 (per soft112 mirror metadata)
- **Framework**: native Java, lightly obfuscated; structured MobileSDK (`com.reconinstruments.mobilesdk.*`: bttransport, hudconnectivity, trips, messages, mediaplayer, phonecontrol, remotekeyboard, timesync, agps...)

## Open questions
1. SPP channel roles (control vs. bulk trip transfer) and message framing — MobileSDK is modular enough to read statically.
2. ReconOS app SDK (HUD-side apps) availability — SDK was public; archive.org copies?
3. ADB enablement path on stock Snow2 firmware.

## Status
- APK acquired: yes. Decompiled: yes (triage). UUIDs: SPP channel UUIDs recovered. Protocol framing: TBD.
- safety_class: LOW (display-only; no actuation).
