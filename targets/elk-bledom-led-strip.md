# Target: ELK-BLEDOM Generic BLE LED Strip Controller

## Target metadata
- target_id: elk-bledom-led-strip
- app package_id(s): com.Zhiling.DuoCoStripLight, com.lotuslantern.ledble, com.auraLed
- device class: BLE LED strip controller
- transport(s): BLE
- local-only viability: high — purely BLE, no cloud dependency

## Known facts (verified from RE sources)
- Sold under dozens of brand names: JACKYLED, auraLED, HueLite, MELK, LEDBLE, ELK-BULB, ELK-LAMPL
- Extremely cheap ($2-15 from AliExpress/Amazon)
- VERIFIED (source: FergusInLondon/ELK-BLEDOM): BLE service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- VERIFIED: Write characteristic UUID: `0000fff3-0000-1000-8000-00805f9b34fb`
- VERIFIED: 9-byte packet format: Byte1=0x7E (start), Byte2=sequence/ID (0x00-0x07), Byte3=command type, Bytes4-7=parameters, Byte8=0x00 or 0x10, Byte9=0xEF (end)
- VERIFIED: Command 0x05/0x03 = set RGB color, Command 0x01 = set brightness
- VERIFIED: Device also advertises HID service 0x1812 (not actually implemented — ignore)
- TBD — needs verification: Read characteristic UUID 0xFFF4 (not confirmed in primary RE source)
- Multiple open-source RE projects exist but no unified protocol spec
- Existing RE: github.com/FergusInLondon/ELK-BLEDOM, github.com/dave-code-ruiz/elkbledom, github.com/arduino12/ble_rgb_led_strip_controller

## Device discovery signals
- BLE:
  - advertised name patterns: "ELK-BLEDOM", "MELK", "LEDBLE", "ELK-BULB", "ELK-LAMPL" (VERIFIED via elkbledom HA integration)
  - service UUIDs: `0000fff0-0000-1000-8000-00805f9b34fb`
  - address behavior: public

## Threat model + guardrails
- Scope: only owned devices, no safety-critical use cases.
- LED strip only — no safety risk beyond light output.

## First experiments (do these first)
1) Run ./scripts/detect_devices.sh; attach log paths.
2) Fetch APK (apkeep) OR pull from device (adb).
3) Static: grep for UUIDs/endpoints + identify transport stack.
4) Dynamic: record one "connect + set color" HCI/PCAP.

## Protocol hypotheses (to validate)
- Pairing/bonding steps: no bonding required, open BLE write (VERIFIED)
- Session state machine: connect → write characteristic → disconnect
- Commands: color set (RGB) via cmd 0x05/0x03, brightness via cmd 0x01, on/off, mode/effect selection (VERIFIED)
- Payload encoding: fixed 9-byte packets [0x7E, seq, cmd, p1, p2, p3, p4, flag, 0xEF] (VERIFIED)
- Timing constraints: TBD — needs verification

## Control surface inventory (what the replacement app must support)
- Onboarding/pairing UX: BLE scan for ELK-BLEDOM name
- Core controls (MVP): on/off, color (RGB), brightness
- Power / brightness / modes / uploads: multiple effect modes (strobe, fade, etc.)
- Error handling and recovery: reconnect on disconnect
- Settings persistence: TBD — needs verification

## Evidence checklist
- APK hashes + version code: TBD
- HCI snoop log: TBD

## Spec output (clean-room)
Write a derived spec in:
- docs/specs/elk-bledom-led-strip.md
- include message formats, UUIDs, examples, and tests.

## References (URLs only)
- https://github.com/FergusInLondon/ELK-BLEDOM
- https://github.com/dave-code-ruiz/elkbledom
- https://github.com/arduino12/ble_rgb_led_strip_controller
- https://github.com/kquinsland/JACKYLED-BLE-RGB-LED-Strip-controller
