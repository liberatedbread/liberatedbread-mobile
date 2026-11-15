# Target: iTag BLE Bluetooth Tracker

## Target metadata
- target_id: itag-ble-tracker
- app package_id(s): com.nut.blehunter (and various iTag apps)
- device class: BLE key finder / anti-loss tracker
- transport(s): BLE
- local-only viability: high — simple BLE device, no cloud

## Known facts (verified from RE sources)
- iTag BLE key finder (source: thejeshgn.com RE blog post)
- Price: $1-2
- CR2032 battery, LED and buzzer
- VERIFIED: Immediate Alert service: `00001802-0000-1000-8000-00805f9b34fb`, char: `00002a06` (WRITE, WRITE_WITHOUT_RESPONSE, NOTIFY)
- VERIFIED: Button service: `0000ffe0-0000-1000-8000-00805f9b34fb`, char: `0000ffe1` (READ, NOTIFY)
- VERIFIED: Battery service: `0000180f-0000-1000-8000-00805f9b34fb`, char: `00002a19` (READ, NOTIFY)
- VERIFIED: Alert levels: 0=off, 1=mild, 2=high (triggers buzzer + LED)
- VERIFIED: "Almost every iTag manufacturer uses characteristic 0xFFE1 for button click" (quasi-standard)
- VERIFIED: Double-click detection with 300ms window (iTracing2 app)
- VERIFIED: Hard-coded MAC addresses enable tracking (privacy limitation)
- Known issue: some models drain batteries in hours if not bonded (community reports)
- Existing RE: thejeshgn.com, Gadgetbridge wiki, Edzelf/Itag

## Device discovery signals
- BLE:
  - advertised name patterns: TBD — "iTAG" unconfirmed in cited source
  - service UUIDs: 0x1802 (Immediate Alert), 0xFFE0 (button) — VERIFIED
  - address behavior: public, hard-coded MAC (VERIFIED)

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Simple buzzer/LED — no safety risk.
- Privacy: hard-coded MAC enables tracking.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for common iTag apps.
3) Static: identify GATT services (0x1802, 0xFFE0, 0x180F).
4) Dynamic: trigger buzzer, capture button notification.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: bonding recommended to prevent battery drain — community-documented
- Session state machine: connect -> bond -> subscribe notifications -> use
- Commands: alert write to 0x2A06 (0=off, 1=mild, 2=high) (VERIFIED), button notify on 0xFFE1 (VERIFIED)
- Payload encoding: single byte alert level; button via CCCD (VERIFIED)
- Timing constraints: connection must be maintained for notifications

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan, bond
- Core controls (MVP): trigger buzzer, receive button press (single + double-click)
- Power / brightness / modes / uploads: N/A
- Error handling and recovery: reconnect, handle battery drain
- Settings persistence: bonding state

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/itag-ble-tracker.md

## References (URLs only)
- https://github.com/Freeyourgadget/Gadgetbridge/wiki/iTag
- https://thejeshgn.com/2017/06/20/reverse-engineering-itag-bluetooth-low-energy-button/
- https://github.com/Edzelf/Itag
- https://github.com/s4ysolutions/itag
