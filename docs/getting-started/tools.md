# Recommended Tools

## BLE (Bluetooth Low Energy)

- **nRF Connect** (Mobile) -- Essential for BLE device exploration
- **Wireshark** + **nRF Sniffer** -- Capture BLE traffic over the air
- **btlejack** -- BLE sniffer using Micro:Bit boards
- **Android HCI snoop log** -- Built-in Android BLE logging

## WiFi

- **Wireshark** -- Filter by device IP
- **mitmproxy** -- HTTPS interception for cloud API calls
- **Charles Proxy** -- GUI alternative to mitmproxy

## OBD-II / Vehicle Diagnostics

- **OBDLink LX / MX+** (STN chipset) -- Handles multi-frame ISO-TP and custom headers;
  clone ELM327 adapters often do not
- **SocketCAN + can-utils** (`candump`, `cansend`, `isotpsend`) -- Full frame visibility
  with no AT-command layer in the way
- **SavvyCAN** -- GUI capture, diffing and DBC authoring for CAN logs
- **CANable / PCAN / Kvaser** -- USB CAN interfaces for passive logging
- **Android HCI snoop log** -- Captures the phone-to-adapter link; the ELM327 protocol is
  ASCII, so vendor tool requests are readable in the RFCOMM stream
- `scripts/obd_discover.py` -- Read-only ECU and DID reconnaissance over an ELM327 adapter

See [Common OBD-II patterns](../protocols/obd2-common.md).

## Firmware Analysis

- **binwalk** -- Firmware image extraction
- **Ghidra** -- Open source reverse engineering framework
- **radare2** -- RE framework (CLI)
- **esptool** -- ESP32/ESP8266 firmware flash tool

## APK Analysis

- **jadx** -- Android APK decompiler (Java/Kotlin source recovery)
- **apktool** -- APK resource extraction and rebuild
- **frida** -- Dynamic instrumentation toolkit
- **objection** -- Runtime mobile exploration (built on frida)
