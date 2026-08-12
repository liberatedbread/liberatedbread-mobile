# HOTWIRED Heated Gear — BLE Protocol Research Notes

## APK Provenance
- **Package**: `com.hotwired.mec`
- **Source**: apkeep (Google Play mirror)
- **XAPK SHA-256**: `740c22d3d66a4317abf026ae9ba0e9bb0e31bf0dd20dd533b86d436d581028b3cab`
- **APK SHA-256**: `15796544` bytes extracted from XAPK
- **App framework**: Native Java (no Flutter/React Native)
- **Obfuscation**: Light — package `com.hotwired` mostly unobfuscated
- **Version**: 1.1 (build 8), Android 4.3+

## BLE UUIDs (Recovered from DEX)

### Primary Service
| UUID | Role |
|------|------|
| `0000ffb0-0000-1000-8000-00805f9b34fb` | Service |

### Characteristics
| UUID | Role | Source |
|------|------|--------|
| `0000ffb1-0000-1000-8000-00805f9b34fb` | Write (command) | `BluetoothService.WriteUUID` |
| `0000ffb2-0000-1000-8000-00805f9b34fb` | Read/Notify | `BluetoothService.ReadUUID` |

### Alternate UUIDs (also accepted)
| UUID | Alias for |
|------|-----------|
| `0000fee2-0000-1000-8000-00805f9b34fb` | Write |
| `0000fee1-0000-1000-8000-00805f9b34fb` | Read/Notify |

### CCCD
| UUID |
|------|
| `00002902-0000-1000-8000-00805f9b34fb` |

## Command Protocol (FULLY RECOVERED)

### Frame Format (Write)
```
AA [payload] 00 00 00 00 55
```

- Header: `AA` (1 byte)
- Payload: variable length (command + data)
- Trailer: `00 00 00 00 55` (5 bytes)

### Command Construction
From `BleOrder.sendType(str)`:
```
AA + str + 00 + 00 + 00 + 00 + 55
```

### Heat Level Command
From `BleOrder.control(status, temp)`:
```
sendType(status + buo(temp))
```

Where:
- `status` = heat level hex string (2 chars)
- `temp` = temperature override hex string (2 chars), "00" if not set
- `buo()` pads single-char hex to 2 chars

### Example: Set heat to level 5
```
AA 05 00 00 00 00 00 55
```

### Notification Protocol (Read)

Device responds with either:

**Type AA — Echo/Confirmation:**
```
AA... (echoes set command)
```
If the echo matches the sent command, confirmation is sent. If not, the command is re-sent.

**Type CC — Status Frame:**
```
CC [status:2] [temps:2] [battery:2] [temp:2] [control:2]
```
- Bytes 2-4 (index): status byte
- Bytes 4-6: temps
- Bytes 6-8: battery level
- Bytes 8-10: temperature
- Bytes 10-12: control

### Keep-alive / Retry
- After each write, a 3-second timer is set
- If no matching `AA` echo is received within 3 seconds, the command is re-sent
- `TimerTask` dispatches via `handler2.sendEmptyMessage(10)` → `sendOrder(sets, mBluetoothGatt)`

## BLE Connection Flow
1. Connect to device by MAC address
2. `discoverServices()` after 500ms delay
3. Find Write characteristic (`ffb1` or `fee2`)
4. Find Read characteristic (`ffb2` or `fee1`)
5. Read characteristic, enable notifications
6. Send commands and listen for `AA`/`CC` responses

## Device Discovery
- Scan by MAC address (no name filter found in code)
- Connection is address-based, not name-based
- No scan filter for service UUIDs

## Safety Notes
- Command echo mechanism (AA) confirms writes are applied
- 3-second retry on non-confirmation
- Status frame (CC) provides device state feedback
- **No watchdog/keep-alive found** — device holds setpoint independently
- Off command is just heat level 00

## Files Analyzed
- `com/hotwired/service/BluetoothService.java` — BLE service with UUIDs, connection, notification handling
- `com/hotwired/util/BleOrder.java` — Command construction, hex conversion
- `com/hotwired/mec/ControlActivity.java` — UI control surface
