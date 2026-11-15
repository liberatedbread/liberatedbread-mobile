# Magic Display — target spec starter

## Target metadata
- target_id: magic-display
- app package_id(s): com.tirohk.magicdisplay
- device class: LED display (shoes, bags, hats, crafts)
- transport(s): Bluetooth (BLE)
- local-only viability: high (local BLE control expected for display programming)

## Known facts (public)
- App controls LED displays embedded in various accessories (shoes, bags, hats, crafts).
- 82K+ installs on Play Store; low rating (2.6) suggests opportunity.
- Similar device class to LED name badges and LED backpacks.
- No known community reverse engineering exists.

## Device discovery signals (hypotheses)
- BLE advertised name patterns: unknown (discover via scan; look for "Magic", "Display", or generic names)
- Service UUIDs: unknown (discover via APK analysis + GATT enumeration)
- Address behavior: unknown

## Threat model + guardrails
- Scope: only owned devices.
- No safety concerns; display-only device.

## First experiments
1) Static APK scan (com.tirohk.magicdisplay):
   - search for UUID literals and GATT references
   - search for "magic", "display", "bluetooth", "led", "bitmap"
   - identify command format, display resolution, and encoding
2) Compare protocol patterns with LED name badge and other LED display targets.
3) HCI snoop: connect and set a simple pattern.

## Protocol hypotheses (to validate)
- Pairing/bonding: likely none required
- Display resolution: unknown (varies by product form factor)
- Command format: unknown (likely similar to other cheap LED display controllers)
- Bitmap encoding: unknown

## Control surface inventory
- Send text/image to display
- Set animation mode
- Set brightness
- Set speed

## Evidence checklist
- APK hashes + version code
- HCI snoop log

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/magic-display.md
- device-specs/devices/magic-display.yaml (if enough protocol data found)

## References
- https://play.google.com/store/apps/details?id=com.tirohk.magicdisplay
