# Lascar EL-BT-2 — Research Notes

Bluetooth Classic temperature/humidity data logger from Lascar Electronics (UK).
**Confirmed discontinued; fully local control over SPP; APK acquired and statically analyzed.**

## Abandonment / cloud status
- Lascar's own EasyLog BT page states: "Our Bluetooth data loggers are no longer
  available" ([lascarelectronics.com](https://lascarelectronics.com/software/easylog-software/easylog-bt/), accessed 2026-08-03).
- Marked DISCONTINUED by resellers ([instrumentation2000.com](https://www.instrumentation2000.com/lascar-electronics-el-bt-2.html), [instrumentchoice.com.au](https://www.instrumentchoice.com.au/products/bluetooth-humidity-temperature-logger-android-with-standard-4-point-temperature-and-humidity-calibra)).
- Lascar itself is alive (EasyLog USB/WiFi/Cloud lines continue); only the BT logger line is orphaned.
- **No cloud dependency at all**: app talks SPP directly to the logger; data export is
  local file -> email/cloud of user's choice. App version 1.16 APK is also hosted by Lascar directly.

## Hardware / transport
- Temp -20..+60 C, RH 0..100 %, up to 500k readings, LCD, rechargeable Li-ion, IP55.
- Bluetooth Classic, Class 2 radio (~10 m) ([datasheet](https://www.itm.com/pdfs/cache/www.itm.com/el-bt-2/datasheet/el-bt-2-datasheet.pdf)).
  App predates BLE ubiquity and uses the Android `BluetoothSocket` SPP API only.

## APK Provenance
- **Package**: `com.LascarElectronics.EasyLogBT` ("EasyLog BT")
- **Source**: apkeep, apk-pure (Google Play listing linked from Lascar's site)
- **Version analyzed**: 1.30 (APKPure lists 1.16..1.30)
- **APK SHA-256**: `c8c01d3b427efbef6aa158b88477f2e3da146b9134b6e0b88d15704931581893`
- **Obfuscation**: none meaningful; package `com.LascarElectronics.EasyLogBT` readable.

## Protocol (recovered from DEX)
Connection: SPP UUID `00001101-0000-1000-8000-00805F9B34FB`
(`Globals.java` -> `SerialPortServiceClass_UUID`, classic BluetoothChat-style
ConnectThread/ConnectedThread).

ASCII command set (`Logger_Connected.java:114-120`), each command is a short
slash-prefixed string written raw to the socket, followed by the payload/response:

| Command | Meaning |
|---------|---------|
| `/RC` | Request config — logger replies with 85-byte config block |
| `/BL` | Begin logging — host then sends config block; reply byte `0x0B` = ACK |
| `/EL` | End logging — logger returns config block |
| `/GD` | Get data — download logged readings |
| `/WH` | Write firmware header (OTA update start) |
| `/WF` | Write firmware frame — 32-byte chunks of `firmware.srec` |
| `/RS` | Reset after firmware update |
| `SP,<pin>` | Set 4-digit pairing/config PIN (default `1234`) |

Other recovered details:
- Config block is **85 bytes** (`ConfigBlock.config_block_size = 85`), carrying
  logger name (20 B), serial (9 B), fw version (5 B), sample rate, alarms
  (temp/RH high/low), delayed start, RTC fields, min/max, channel slope/offset
  calibration doubles, battery level.
- Integrity: CRC-16 (reflected, init 0xFFFF — CCITT/Kermit style) computed in
  `crc16()` at `Logger_Connected.java:783`.
- Firmware update header constant: `FFFFFFFF4354424C00BF0100E60E0000`
  (contains ASCII `CTBL`), sent after `/WH`.
- Downloaded logs are stored on-device as plain `.txt` files.

## Feasibility
- **HIGH.** Plain SPP + documented-above ASCII commands; a minimal Python
  `pyserial`/`rfcomm` or PyBluez client can implement `/RC`, `/BL`, `/EL`, `/GD`
  from the constants above. No account, no pairing trickery beyond the PIN.
- The orphaned part (Play-delisted app, no firmware updates) does not block local use.

## Open questions
- Exact on-wire framing of the `/GD` data stream (record size, timestamp epoch)
  — needs one HCI snoop or live session.
- Whether `/WF` OTA is safe to re-host (firmware.srec no longer distributed).

## Files analyzed
- `com/LascarElectronics/EasyLogBT/Globals.java` — SPP UUID, socket threads
- `com/LascarElectronics/EasyLogBT/Logger_Connected.java` — command set, CRC16, OTA
- `com/LascarElectronics/EasyLogBT/Helpers/ConfigBlock.java` — 85-byte config layout
