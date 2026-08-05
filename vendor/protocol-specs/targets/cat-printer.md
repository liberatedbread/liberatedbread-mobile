# Target: Cat Printer (GB01/GB02/GB03/GT01/YT01/MX05-10)

## Target metadata
- target_id: cat-printer
- app package_id(s): TBD — iPrint app not on Play Store; exact package ID unknown
- device class: mini thermal printer
- transport(s): BLE
- local-only viability: high — purely BLE, no cloud

## Known facts (verified from RE sources)
- Cat-shaped mini thermal printer (source: NaitLee/Cat-Printer)
- Price: $15-20
- VERIFIED: Supported models: GB01, GB02, GB03, GT01, YT01, MX05, MX06, MX08, MX10
- VERIFIED: TX characteristic UUID: `0000ae01-0000-1000-8000-00805f9b34fb`
- VERIFIED: RX characteristic UUID: `0000ae02-0000-1000-8000-00805f9b34fb`
- VERIFIED: 1-bit bitmap raster printing
- VERIFIED: Model differences via flags: is_new_kind, problem_feeding, paper_width
- Uses Bleak BLE library; cross-platform Python tool with web UI
- Existing RE: github.com/NaitLee/Cat-Printer, werwolv.net/blog/cat_printer

## Device discovery signals
- BLE:
  - advertised name patterns: "GB01", "GB02", "GB03", "GT01", "YT01", "MX05", "MX06", "MX08", "MX10" (VERIFIED)
  - service UUIDs: VERIFIED: `0000ae30-0000-1000-8000-00805f9b34fb`
  - additional characteristics: AE03 (write data), AE04 (notify), AE05 (indication), AE10 (read/write)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Thermal printer only — no safety risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Identify actual iPrint APK package ID; fetch APK.
3) Static: grep for BLE UUIDs, print command format.
4) Dynamic: record one "connect + print image" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: no bonding required (VERIFIED from tool behavior)
- Session state machine: connect -> configure -> send image -> disconnect
- Commands: print image, feed paper, set energy/darkness (VERIFIED)
- Payload encoding: 1-bit bitmap row-by-row, framing varies by model (VERIFIED)
- Timing constraints: flow control needed for some models

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for GB*/GT*/YT*/MX* names
- Core controls (MVP): print image, feed paper
- Power / brightness / modes / uploads: print darkness/energy
- Error handling and recovery: paper-out, reconnect, problem_feeding models
- Settings persistence: N/A

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/cat-printer.md

## References (URLs only)
- https://github.com/NaitLee/Cat-Printer
- https://werwolv.net/blog/cat_printer
