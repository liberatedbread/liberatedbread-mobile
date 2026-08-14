# Zeemote JS1 — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (SPP + HID).

## Product
Zeemote JS1 (2008–2011): tiny one-hand BT Classic controller — 1 analog stick +
4 buttons (later variants add triggers). Also sold rebranded as Buffalo BSGPJS1H
(Japan). The SteelSeries Free is Zeemote-derived hardware (see steelseries-free.md).

## Company / app status
- Zeemote Inc. was acquired by Aplix Corp in **2011** (Light Reading); the
  technology line died shortly after. No servers were ever involved — but games
  needed the (closed-source) Zeemote SDK to use the proprietary joystick mode.
- The SDK/driver situation was the "app that's gone" problem: solved in the open
  by Bluez-IME (see below).

## Local feasibility verdict: CONFIRMED — three local modes
Mode chosen by the button held at power-on (flatlib.jp Buffalo JS1 review, 2011-12):
- **(A) Pointer mode** — BT HID mouse emulation. Works on any HID host.
- **(B) Keyboard mode** — BT HID keyboard emulation. Works on any HID host.
- **(C) Joystick mode** — proprietary serial over SPP/RFCOMM; needs a driver.
  Fully documented below from the open-source Bluez-IME driver.

Modes A/B alone make the JS1 usable today with zero software. Mode C is usable via
Bluez-IME on Android or any reimplementation from the spec below.

## APK provenance (driver, not vendor app)
- Package: `com.hexad.bluezime` (Bluez-IME 1.20, open source — Zeemote JS1,
  MSI BGP100, Phonejoy, iControlPad, iCade, Wiimote drivers)
- Source: F-Droid archive direct fetch (`f-droid.org/archive/com.hexad.bluezime_20.apk`);
  apkeep's f-droid source failed on repo extraction, direct HTTP worked.
  2016-06-20 build. SHA-256: `99b4aa59e5f1f7b6b0b2db06df4af1567f1d5616b446cae242dc075d33f02b79`
- Decompiled with jadx to workspace/static/zeemote-js1/ (triage pass).

## Joystick-mode (SPP) protocol — from Bluez-IME ZeemoteReader.java
- RFCOMM connect; if the default SDP record fails, use service UUID
  `8e1f0cf7-508f-4875-b62c-fbb67fd34812`.
- Frame: `[len, 0xA1, msgType, payload...]` (len counts bytes after itself).
- msgType `0x07` = button update (original JS1); `0x1C` = button update
  (SteelSeries/Free-style variant). Payload = list of pressed button indices
  (each < 16); absence = released.
- msgType `0x08` = axis update: byte3 = axis-pair index; bytes 4–5 = X, Y (int8,
  ~±127 range in practice).
- Buttons map to 12 logical controls: A/B/C/D, L/R shoulders, d-pad directions
  (per Bluez-IME key tables).

## Community RE
- Bluez-IME (above) is the canonical open driver; F-Droid keeps it buildable.
- Emu-EX-plus-alpha (github.com/Rakashazi/emu-ex-plus-alpha) ships native Zeemote
  support on Android/iOS/Linux (explusalpha.com Bluetooth docs).
- AnkiDroid wiki documents Bluez-IME as the way to use a JS1 on modern Android.

## Open questions
- Exact RFCOMM channel/SDP record name on JS1 vs Buffalo vs SteelSeries variants.
- Buffalo-mode differences (flatlib.jp implies identical modes).
- Trigger-button message variants on later JS1 revisions.

## Sources
- lightreading.com — "Zeemote Acquired by Aplix" (2011)
- wlog.flatlib.jp/2011/12/02/n1540/ — three modes, HID vs SPP (Japanese)
- fdroid.gitlab.io package page + F-Droid archive APK — Bluez-IME 1.20
- workspace/static/zeemote-js1/.../ZeemoteReader.java — protocol constants
- explusalpha.com/contents/emuex/bluetooth-old — native emulator support
