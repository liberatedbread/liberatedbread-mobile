# Bluetooth LED Name Badge — target spec starter

## Target metadata
- target_id: bluetooth-led-name-badge
- app package_id(s): com.yannis.ledcard
- device class: LED name badge / scrolling text display
- transport(s): Bluetooth (BLE)
- local-only viability: high (fully local BLE control; no cloud dependency)

## Known facts (public)
- Cheap programmable LED name badges with 11x44 or 12x48 LED matrices.
- Extensively reverse engineered by community: FOSSASIA BadgeMagic, Nilhcem, M4GNV5/BluetoothLEDBadge.
- Known protocol: Service UUID 0xFEE0, Characteristic 0xFEE1, device name "LSLED".
- 16-byte BLE writes; header "wang" (0x77616E67); bitmap encoding.
- Supports up to 8 message slots with individual animation modes.

## Device discovery signals (hypotheses)
- BLE advertised name patterns: "LSLED"
- Service UUIDs: 0000fee0-0000-1000-8000-00805f9b34fb
- Address behavior: public (verify)

## Threat model + guardrails
- Scope: only owned devices.
- No safety concerns; display-only device.

## First experiments
1) Static APK scan (com.yannis.ledcard):
   - search for UUID literals (FEE0, FEE1)
   - search for "wang", "lsled", "badge", "bitmap"
   - identify message slot encoding and animation modes
2) Cross-reference with FOSSASIA BadgeMagic protocol docs.
3) HCI snoop: connect and send a simple text message.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: no pairing required ("just works")
- Commands: write bitmap data in 16-byte chunks to characteristic 0xFEE1
- Packet 1: header "wang" (77 61 6E 67) + flash/marquee/animation flags
- Packet 2: message lengths (2 bytes per slot, up to 8 slots)
- Packet 3: timestamp (YY MM DD HH MM SS)
- Packet 4: separator (all zeros)
- Packets 5+: bitmap data (11 bytes per character column)
- Payload encoding: raw bitmap, MSB first, 1 bit per LED

## Control surface inventory
- Send text message (converted to bitmap)
- Set animation mode per slot (static, scroll left/right/up/down, blink, etc.)
- Set brightness
- Set speed

## Evidence checklist
- APK hashes + version code
- HCI snoop log

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/bluetooth-led-name-badge.md
- device-specs/devices/bluetooth-led-name-badge.yaml

## References
- https://play.google.com/store/apps/details?id=com.yannis.ledcard
- https://github.com/fossasia/badgemagic-app
- https://github.com/fossasia/badgemagic-firmware
- http://nilhcem.com/iot/reverse-engineering-bluetooth-led-name-badge
- https://github.com/M4GNV5/BluetoothLEDBadge
