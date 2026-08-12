# Research Notes: iTag BLE Bluetooth Tracker

## Source Repos
- Edzelf/Itag — ESP32 Arduino client using NimBLE
- thejeshgn.com — RE blog post with GATT service discovery
- Gadgetbridge wiki — iTag support documentation

## Key Findings

### BLE Services and Characteristics
- **Immediate Alert** (0x1802): char 0x2A06 (write, write-without-response)
  - Alert levels: 0x00=off, 0x01=mild, 0x02=high (buzzer+LED)
- **Button Service** (0xFFE0): char 0xFFE1 (read, notify)
  - Quasi-standard across iTag manufacturers
  - Button press notifications
  - CCCD (0x2902) may NOT exist on some models
- **Battery Service** (0x180F): char 0x2A19 (read, notify)
  - Battery percentage as uint8 (0-100)

### Protocol Notes
1. Connect BLE
2. Write alert level to 0x2A06 to trigger buzzer/LED
3. Subscribe to 0xFFE1 notifications for button press events
4. Read 0x2A19 for battery level

### NimBLE Library Workaround
- Some iTags are not fully BLE-compliant
- CCCD descriptor 0x2902 may not exist
- NimBLE subscribe() works even without 0x2902 descriptor
- "Subscribe tries to write the value of the first parameter to descriptor
  0x2902. It seems that there is no 0x2902 descriptor, so 'false' is returned"
  — Edzelf/Itag source
- Continue anyway after failed CCCD — notifications may still work

### Button Detection
- Double-click detection: use 300ms debounce window (from iTracing2 app)
- 500ms debounce in Edzelf/Itag ESP32 implementation
- Hard-coded MAC addresses enable tracking (privacy limitation)

### Battery Drain Issue
- Community reports: some models drain batteries in hours if NOT bonded
- Bonding is recommended but not strictly required for basic operation

### Hardware
- CR2032 battery
- LED + buzzer
- Price: $1-2

## Confidence
- HIGH: alert service and characteristic UUIDs
- HIGH: button service (0xFFE0/0xFFE1) — quasi-standard across manufacturers
- HIGH: battery service
- MEDIUM: exact name patterns (vary by OEM)
- LOW: bonding behavior (varies by firmware version)
