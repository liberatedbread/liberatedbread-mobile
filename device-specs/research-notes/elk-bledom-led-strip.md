# Research Notes: ELK-BLEDOM Generic BLE LED Strip Controller

## Source Repos
- FergusInLondon/ELK-BLEDOM — primary RE, clean-room from Android APK
- dave-code-ruiz/elkbledom — Home Assistant integration
- arduino12/ble_rgb_led_strip_controller — Arduino example
- kquinsland/JACKYLED-BLE-RGB-LED-Strip-controller — Python client

## Key Findings

### BLE Details
- Service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- Write characteristic: `0000fff3-0000-1000-8000-00805f9b34fb`
- Read characteristic: `0000fff4-...` (unconfirmed, not from primary source)
- Advertises HID service 0x1812 but does NOT implement it
- Advertised names: "ELK-BLEDOM", "MELK", "LEDBLE", "ELK-BULB", "ELK-LAMPL"

### Protocol
- Fixed 9-byte packets: `[0x7E][seq][cmd][p1][p2][p3][p4][flag][0xEF]`
- Write-only — no responses from device
- No pairing, no bonding, no auth
- Byte 2: sequence number (0x00 works)
- Byte 8: 0x00 or 0x10 (both work)
- 15 commands total (6 visual, 9 control), from Android APK
- The app distinguishes "data" vs "control" message types

### Verified Commands
- Color change (cmd 0x05 sub 0x03): `[0x7E, seq, 0x05, 0x03, R, G, B, flag, 0xEF]`
- Brightness (cmd 0x01): `[0x7E, seq, 0x01, brightness, light_mode, 0x00, 0x00, flag, 0xEF]`
- Color temp (cmd 0x05 sub 0x02): `[0x7E, seq, 0x05, 0x02, warm, cold, 0x00, 0x00, flag, 0xEF]` (warm + cold = 100)
- Single color (cmd 0x05 sub 0x01): `[0x7E, seq, 0x05, 0x01, color, 0xFF, 0xFF, flag, 0xEF]`

### Hardware
- Unmarked 16-pin SMD MCU with 24MHz oscillator
- N-Channel MOSFETs (A2SHB) for PWM
- 7533M LDO: 3.3V from max 24V input; MOSFETs rated to 20V/3.5A
- No status LEDs on device

## Confidence
- HIGH: service UUID, write characteristic, 9-byte packet format, color/brightness commands
- MEDIUM: read characteristic 0xFFF4, timing/calendar commands
- LOW: mic streaming, advanced mode commands
