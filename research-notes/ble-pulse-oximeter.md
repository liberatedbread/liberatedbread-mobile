# BLE Pulse Oximeter — Research Notes

## APK Provenance
- **Package**: `com.wakeup.smartspo` ("Wearfit BO" app)
- **Source**: apkeep (Google Play mirror)
- **APK SHA-256**: `37834803` bytes (bare APK, not XAPK)
- **App framework**: Native Java + Nordic DFU library
- **Obfuscation**: Light — main packages (`com.wakeup.smartspo`) unobfuscated
- **Note**: This is a companion app for Wearfit smart bands/bracelets. It may also work with the SP001 pulse oximeter per jcomas/PulseOximeterSP001 repo.

## BLE UUIDs (Recovered from DEX)

### Nordic UART Service (Primary)
From `BleService.java`:
| UUID | Role |
|------|------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | RX Service (Nordic UART) |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | RX Characteristic (Write to device) |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | TX Characteristic (Notify from device) |

### SMART_BRACELET Service (Alternate/Custom)
From `GattAttributes.java`:
| UUID | Role |
|------|------|
| `0000fff0-0000-1000-8000-00805f9b34fb` | SMART_BRACELET Service |
| `0000fff4-0000-1000-8000-00805f9b34fb` | SMART_BRACELET Measurement |

### Standard Services
| UUID | Service |
|------|---------|
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information Service |
| `00001804-0000-1000-8000-00805f9b34fb` | TX Power Service |
| `00002a07-0000-1000-8000-00805f9b34fb` | TX Power Level |
| `00002a26-0000-1000-8000-00805f9b34fb` | Firmware Revision String |
| `00002902-0000-1000-8000-00805f9b34fb` | CCCD |

### SMART_BRACELET_CONF
| UUID | Role |
|------|------|
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | Configuration (same as TX_CHAR) |

## Architecture
- `BleService.java` — Main BLE service with Nordic UART implementation
- `BluetoothLeService.java` — Secondary BLE service
- `GattAttributes.java` — UUID lookup table
- `BleUtil.java` — BLE utility functions
- Uses Nordic DFU library (`no.nordicsemi.android.dfu`) for firmware updates
- Packet-based data transfer (SEND_PACKET_SIZE = 20 bytes, MTU-3)
- Event-driven via EventBus (`de.greenrobot.event.EventBus`)
- Data handling: `DataHandlerUtils`, `DataPacket`, `BroadcastCommand`, `BroadcastData`

## Connection Flow
1. Scan by MAC address (stored in SharedPreferences as `BIND_DEVICE_ADDRESS`)
2. Connect via `connectGatt()`
3. Discover services
4. Enable notifications on CCCD
5. Receive data via `onCharacteristicChanged()` callback

## Data Protocol
- **Nordic UART**: Standard async serial bridge
- Write commands to `6e400002` (RX_CHAR)
- Receive notifications on `6e400003` (TX_CHAR)
- 20-byte packet size
- Uses `chignon` package for data packet parsing (`BroadcastCommand`, `BroadcastData`, `DataPacket`)

## Next Steps
1. **Capture HCI snoop** of actual oximeter data to decode SpO2/PR/PI frame format
2. Check if the `0000fff0`/`0000fff4` alternate service is used by SP001 specifically
3. The `chignon` package may contain the data frame parser — analyze for measurement encoding
4. Compare with jcomas/PulseOximeterSP001 repo for known frame format

## Files Analyzed
- `com/wakeup/smartspo/model/ble/GattAttributes.java` — UUID definitions
- `com/wakeup/smartspo/ble_service/BleService.java` — Main BLE service
- `com/wakeup/smartspo/service/BluetoothLeService.java` — Secondary BLE service
- `com/wakeup/smartspo/utils/BleUtil.java` — BLE utilities
- `com/phy/ota/sdk/` — OTA firmware update SDK
