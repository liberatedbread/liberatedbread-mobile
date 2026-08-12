# Quicco Sound mi.1 family (BLE MIDI retrofit adapters) — Research Notes

## What it is
DIN-5 MIDI -> BLE MIDI retrofit adapters from QUICCO SOUND, a small venture in
Hamamatsu, Japan: mi.1 (2015, one of the first BLE-MIDI adapters), mi.1 II,
mi.1 Cable (paired instrument-to-instrument wireless MIDI), and mi.1e
(Eurorack sequencer/LFO module driven by an iPad app). Bus-powered from the
MIDI OUT port; needs no external power on compatible gear.

## Why it's at-risk (honest rating: hypothesis, not confirmed)
- One-person-scale venture; site [quiccosound.jp](https://quiccosound.jp/) is
  online (checked 2026-08-04) but product content dates to ~2021 and retail
  availability is essentially used-market only (e.g. Reverb listings).
- No visible new activity, socials, or firmware releases in years. Treat the
  brand as dormant/at-risk rather than confirmed dead — no insolvency filing
  found (Japanese small-company records not easily searchable).
- If the company vanishes, almost nothing is lost: see below.

## Local BLE feasibility: TRIVIAL (confirmed by design)
- mi.1 implements the **standard BLE MIDI** profile (service
  `03b80e5a-ede8-4b33-a751-6ce34ec4c700`, char
  `7772e5db-3868-4112-a1a9-f2669d106bf3`). It pairs with iOS/macOS/Windows/
  Android BLE-MIDI stacks and third-party tools with zero vendor software —
  this is the whole point of the device and is corroborated by independent
  tooling (e.g. NEWBODYFRESHER's MIDIberry/BT2Reaper list mi.1 as a supported
  generic BLE-MIDI device; CME's WIDI interoperability notes).
- There is essentially **nothing to reverse-engineer**: any host that speaks
  BLE-MIDI owns the device. The repo value here is a provenance/ownership note,
  not a protocol recovery.

## What needs the vendor
- Firmware updates and mode config use the "mi.1 connect" app (per
  [quicco.co.jp FAQ](http://quicco.co.jp/faq/)); believed iOS-only — Android
  package id unverified, not found on apk-pure mirrors searched. If the company
  dies, units on old firmware keep working; only future updates are lost.
- mi.1e Eurorack module is app-driven (iPad) and would be genuinely orphaned —
  its app is the product.

## APK
- None located (Android app existence unconfirmed; iOS "mi.1 connect").
  apk_acquired: false.

## Open questions
- Confirm corporate status (Japanese registry) if this becomes a priority.
- Does "mi.1 connect" exist for Android at all?
- mi.1e iPad app protocol (BLE-MIDI SysEx? custom GATT?) — un-RE'd.

## Safety
None.
