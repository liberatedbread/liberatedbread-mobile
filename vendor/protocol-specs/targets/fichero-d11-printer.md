# Target: Fichero / AiYin D11 Thermal Label Printer

## Target metadata
- target_id: fichero-d11-printer
- app package_id(s): com.lj.fichero
- device class: thermal label printer
- transport(s): BLE + Bluetooth Classic SPP
- local-only viability: high — purely BLE/BT, no cloud

## Known facts (verified from RE sources)
- Fichero/AiYin D11s thermal label printer (source: 0xMH/fichero-printer)
- Price: $15-20
- VERIFIED: 4 BLE UART services (all functionally equivalent): 0x18f0, 0xff00, e7810a71..., 49535343...
- VERIFIED: Write characteristics: `2af1`, `ff02`, `bef8d6c9...`, `4953...9bb3` (per service)
- VERIFIED: Notify characteristics: `2af0`, `ff01`/`ff03` (per service)
- VERIFIED: Print width 96px (12 bytes per row), `0C 00` in LE
- VERIFIED: Raster header command: `1D 76 30`
- VERIFIED: Enable printing: `10 FF FE 01`
- VERIFIED: Stop printing: `10 FF FE 45`
- VERIFIED: Advertised names: "FICHERO_XXXX", "D11s_" prefix
- VERIFIED: Supports both BLE and Classic Bluetooth SPP
- VERIFIED: 18500 Li-Ion battery with USB-C charging, 203 DPI printhead
- NOTE: Previously described as "LuckPrinter SDK" — actual protocol uses AiYin commands per docs/PROTOCOL.md
- Python CLI and Web GUI available
- Existing RE: github.com/0xMH/fichero-printer

## Device discovery signals
- BLE:
  - advertised name patterns: "FICHERO_XXXX", "D11s_" (VERIFIED)
  - service UUIDs: 0x18f0, 0xff00, e7810a71..., 49535343... (VERIFIED)
  - address behavior: TBD

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Label printer only — no safety risk.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) for com.lj.fichero.
3) Static: identify AiYin protocol layer in decompiled APK.
4) Dynamic: record one "connect + print label" HCI snoop.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: TBD
- Session state machine: connect -> enable (`10 FF FE 01`) -> send raster (`1D 76 30` + data) -> stop (`10 FF FE 45`)
- Commands: enable, raster print, stop (VERIFIED)
- Payload encoding: 1-bit raster, 12 bytes/row (96px), preceded by `1D 76 30` header (VERIFIED)
- Timing constraints: TBD

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for FICHERO/D11s name
- Core controls (MVP): print label image, set label size
- Power / brightness / modes / uploads: print darkness
- Error handling and recovery: reconnect on disconnect
- Settings persistence: N/A

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/fichero-d11-printer.md

## References (URLs only)
- https://github.com/0xMH/fichero-printer
