# iLEDColor LED Panel — BLE Protocol Research Notes

## APK Provenance
- **Package**: `com.led.iledcolor`
- **Source**: apkeep (Google Play mirror)
- **XAPK SHA-256**: `df33e91e2467f7c379bcaa7b497bb1bed91aea9a282817b1af632283d79f1505`
- **APK SHA-256**: `27630557` bytes extracted from XAPK
- **App framework**: Native Java with JL (JieLi) Bluetooth OTA SDK
- **Obfuscation**: Heavy ProGuard — all packages obfuscated to single/two-letter names (`ec`, `ob`, `bc`, `qb`, etc.)
- **Native libs**: armeabi_v7a split APK present (9.4MB), indicating native BLE/JL code

## BLE UUIDs (Recovered from DEX)

### JL OTA Service (for firmware updates)
From `ob/b.java`:
| UUID | Role |
|------|------|
| `0000ae00-0000-1000-8000-00805F9B34FB` | JL OTA Service |
| `0000ae01-0000-1000-8000-00805F9B34FB` | JL OTA Write Characteristic |
| `0000ae02-0000-1000-8000-00805F9B34FB` | JL OTA Notify Characteristic |

### Standard BLE Services (also referenced)
| UUID | Standard Service |
|------|-----------------|
| `00001101-0000-1000-8000-00805F9B34FB` | Serial Port Profile (SPP) |
| `0000110b-0000-1000-8000-00805F9B34FB` | Audio Sink |
| `0000111e-0000-1000-8000-00805F9B34FB` | Handsfree |

## Architecture

The app is built on the **JieLi (JL) Bluetooth OTA SDK**:
- `ec/f.java` extends `com.jieli.jl_bt_ota.impl.a` — JL OTA implementation
- `ec/c.java` — Custom BLE manager (`BleManager`) wrapping JL SDK
- `ec/i.java` — Send data thread for BLE writes with queuing
- `bc/s.java` — Device manager (singleton pattern)
- `qb/` — JL SDK core

### BLE Manager (`ec/c.java`)
- Wraps Android `BluetoothManager`, `BluetoothLeScanner`
- Manages multiple GATT connections (list of `BluetoothGatt`)
- Tracks device list and scan results
- Uses `ScanFilter` and `ScanSettings` for BLE scanning

### Write Path
From `ec/f.java`:
```java
this.f7254h0.F(bluetoothDevice, ob.b.f21076o, ob.b.f21077p, bArr, callback);
```
- Service UUID: `ob.b.f21076o` = `0000ae00-...`
- Characteristic UUID: `ob.b.f21077p` = `0000ae01-...`
- Uses queued writes via `ec/i.java` thread

## Key Finding: App Uses JL OTA Protocol
The `0000ae00` service family is the **JieLi Bluetooth OTA protocol** — NOT a custom LED control protocol. This means:
1. The app likely uses JL's proprietary SDK for all BLE communication
2. LED control commands are sent through JL's data pipe (probably `0000ae01`)
3. The actual LED command format is encoded within JL's protocol frames
4. Native `.so` libraries (`config.armeabi_v7a.apk` contains native JL code) handle protocol encoding

## Device Discovery
- Scanning uses `BluetoothLeScanner` with `ScanFilter`
- No obvious name filter found in obfuscated code (may be in native lib)
- Target doc mentions DreamPanel v3 with horizontal serial number rendering

## Next Steps
1. **HCI snoop is essential** — static analysis cannot recover the LED command format
   because it's embedded in JL's proprietary protocol inside native libraries
2. Probe for `0xFF20` service (SPOTLED compatibility) first
3. Capture: connect → set brightness → upload one small GIF
4. Check if device works when logged out (account may be optional for control)
5. Extract protocol details from native `.so` via `strings` and disassembly if snoop is unavailable

## Files Analyzed
- `ob/b.java` — UUID constants (JL OTA service UUIDs)
- `ec/a.java` — BLE callback interface
- `ec/c.java` — BLE manager implementation
- `ec/f.java` — JL OTA handler (extends JL SDK)
- `ec/i.java` — BLE send data thread
- `ec/j.java` — Notification enable runnable
- `bc/s.java` — Device manager
