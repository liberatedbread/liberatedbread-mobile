# Automatic Link / Pro driving adapter (Automatic Labs) — Research Notes

## What it is
OBD-II dongle + phone app for trip logging, crash detection, fuel/diagnostics.
Gen 1/2 "Link" talked **Bluetooth Classic** to the phone; "Pro" added 3G.
Company acquired by SiriusXM, then shut down.

## Cloud status: dead, dated
Automatic Labs shut down **2020-05-28 23:59 PT**; all services including crash
notification ended. Sources:
- https://9to5mac.com/2020/05/01/automatic-labs-shutting-down/ (2020-05-01)
- https://thebanksreport.com/dealers/siriusxm-owned-connected-vehicle-platform-automatic-labs-to-shut-down/
- https://listenercare.siriusxm.com/... KC-2203 "Automatic Labs Update"
Adapters have been e-waste for most owners since; the app is delisted from Play.

## APK provenance
- **Package**: `com.automatic`
- **Version**: 1.14.2 (54908), bare APK (18 MB)
- **SHA-256**: `9374f4556b003a618c2a804115b215449a391c47aa944f4cb26aadae5bee5425`
- **Source**: apkeep / apk-pure (still fetchable 2026-08-04 despite delisting)
- Decompiled (triage) with jadx → `$REPO/workspace/static/automatic/`

## Static findings
- Transport is **Bluetooth Classic RFCOMM**, not BLE GATT:
  `com/automatic/provider/bluetooth/BluetoothProvider.java` uses
  `BluetoothAdapter`/sockets with SPP UUID `00001101-...` plus a custom SDP/RFCOMM
  UUID `22f419c0-b3b6-11e4-a2ad-0002a5d5c51b`.
- `com/automatic/util/Utils.java` computes **HMAC-SHA1 keyed with the ASCII string
  `d1ce1c12-c8c3-45d1-b621-cb70e6aff2fb`** — likely the adapter pairing/auth or
  message-integrity scheme; recovered "for free" from the APK.
- `com/milesense/` contains a state-machine library (the OBD stack Automatic built
  from the MileSense acquisition). No ELM327 AT-command strings surfaced in triage
  — evidence the Link speaks a **proprietary framed protocol**, not ELM327.
- No prior community RE of the adapter protocol found.

## Local feasibility: UNPROVEN (hard)
The radio link is local (phone↔adapter over RFCOMM), so a local client is
physically possible: open SPP, reproduce the HMAC handshake, replay the milesense
state machine. But every byte of the application protocol needs RE from the APK
(large, obfuscated-ish 2015-era codebase) or from a live adapter capture, and the
payoff overlaps the repo's existing generic ELM327 coverage — a $10 Vgate dongle
does the same job. Value here is mostly historical/e-waste-diversion.

## Open questions
- Is the RFCOMM protocol identical across Link v1/v2? (Pro is cellular-first.)
- Does the HMAC key above gate session setup, or only message signing?
- Any diagnostic PID passthrough mode that would let generic OBD tools reuse it?

## Safety
Read-only vehicle diagnostics via OBD-II; no write/control path documented. LOW.
Note: driving/trip adapter, not safety-critical.
