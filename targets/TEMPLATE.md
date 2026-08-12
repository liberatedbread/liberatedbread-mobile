# Target spec template

## Target metadata
- target_id:
- app package_id(s):
- device class:
- transport(s): BLE / Bluetooth Classic / Wi-Fi AP / Wi-Fi LAN / USB
- local-only viability: (high / medium / low) + rationale

## Known facts (public + observed)
- Public claims (paraphrase; link source in References)
- Observed from scans / captures (logs paths)

## Device discovery signals
- BLE:
  - advertised name patterns:
  - service UUIDs:
  - address behavior (public/random):
- Wi-Fi:
  - SSID patterns:
  - default gateway IPs:
  - mDNS service types:
  - UPnP URNs / LOCATION:

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- Explicit non-goals and exclusions.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) OR pull from device (adb).
3) Static: grep for UUIDs/endpoints + identify transport stack.
4) Dynamic: record one “connect + one action” HCI/PCAP.

## Protocol hypotheses (to validate)
- Pairing/bonding steps:
- Session state machine:
- Commands:
- Payload encoding:
- Timing constraints:

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX
- Core controls (MVP)
- Power / brightness / modes / uploads
- Error handling and recovery
- Settings persistence

## Evidence checklist
- APK hashes + version code
- HCI snoop log
- PCAP logs (if Wi-Fi)
- Screenshots (optional; do not commit proprietary UI assets)

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/<target_id>.md
- include message formats, UUIDs, examples, and tests.

## References (URLs only)
- Link1
- Link2
