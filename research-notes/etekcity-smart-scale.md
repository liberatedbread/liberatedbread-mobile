# ETEKCITY ESN00 Smart Scale — BLE Protocol Research Notes

## APK Provenance
- **Package**: `com.etekcity.vesyncplatform` (VeSync Platform app)
- **Source**: apkeep (Google Play mirror)
- **XAPK SHA-256**: `ec0b8b02c52801851b85ca45dae8c56e5cce469bd7e3e0dc859ddd354b7185e3`
- **APK SHA-256**: Extracted from XAPK
- **App framework**: Native Java + Kotlin, 72,998 classes — **massive multi-device platform app**
- **Obfuscation**: Heavy ProGuard — packages obfuscated (`l80`, `p70`, `u92`, etc.)
- **Native libs**: armeabi_v7a split APK present

## Critical Discovery: Multi-Device Platform
The VeSync app is NOT just a scale app — it's a **unified BLE platform** supporting dozens of device types:
- Kitchen/nutrition scales
- Body composition scales  
- Fitness bracelets (Ido platform)
- Heart rate monitors
- Blood pressure monitors
- Environmental sensors
- Jump ropes

This means the APK contains protocol specs for MANY devices, not just the ESN00 scale.

## BLE UUIDs — Scale Service (FFA0 family)
From `p70/j.java` — the primary UUID constant interface:
| UUID | Role |
|------|------|
| `0000ffa0-0000-1000-8000-00805f9b34fb` | **Scale Service** (primary) |
| `0000ffa1-0000-1000-8000-00805f9b34fb` | Characteristic 1 (Write?) |
| `0000ffa2-0000-1000-8000-00805f9b34fb` | Characteristic 2 (Notify?) |
| `0000ffa3-0000-1000-8000-00805f9b34fb` | Characteristic 3 |
| `0000ffa4-0000-1000-8000-00805f9b34fb` | Characteristic 4 |

## BLE UUIDs — Sensor Device Service (FFE0 family)
From `p70/j.java` and `SensorDevice.java`:
| UUID | Role |
|------|------|
| `0000ffe0-0000-1000-8000-00805f9b34fb` | Sensor Service |
| `0000fff3-0000-1000-8000-00805f9b34fb` | Sensor Characteristic (Write) |
| `0000fff5-0000-1000-8000-00805f9b34fb` | Sensor Characteristic (Notify) |

## BLE UUIDs — Additional Scale Characteristics
From `p70/j.java`:
| UUID | Role |
|------|------|
| `0000fff1-0000-1000-8000-00805f9b34fb` | Scale data channel 1 |
| `0000fff2-0000-1000-8000-00805f9b34fb` | Scale data channel 2 |
| `0000ffe1-0000-1000-8000-00805f9b34fb` | Scale config |
| `0000ffe2-0000-1000-8000-00805f9b34fb` | Scale status |

## Standard BLE Services (for body composition data)
| UUID | Standard Service |
|------|-----------------|
| `00001805-0000-1000-8000-00805f9b34fb` | Current Time |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information |
| `0000180d-0000-1000-8000-00805f9b34fb` | Heart Rate |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery Service |
| `0000181b-0000-1000-8000-00805f9b34fb` | Body Composition (standard!) |
| `0000181c-0000-1000-8000-00805f9b34fb` | User Data |
| `0000181d-0000-1000-8000-00805f9b34fb` | Weight Scale (standard!) |

## Standard Characteristics
| UUID | Characteristic |
|------|---------------|
| `00002a19-0000-1000-8000-00805f9b34fb` | Battery Level |
| `00002a25-0000-1000-8000-00805f9b34fb` | Serial Number |
| `00002a2b-0000-1000-8000-00805f9b34fb` | Current Time |
| `00002a37-0000-1000-8000-00805f9b34fb` | Heart Rate Measurement |
| `00002a80-0000-1000-8000-00805f9b34fb` | Age |
| `00002a85-0000-1000-8000-00805f9b34fb` | Date of Birth |
| `00002a8c-0000-1000-8000-00805f9b34fb` | Gender |
| `00002a8e-0000-1000-8000-00805f9b34fb` | Height |
| `00002a9b-0000-1000-8000-00805f9b34fb` | Body Composition Feature |
| `00002a9c-0000-1000-8000-00805f9b34fb` | Body Composition Measurement |
| `00002a9d-0000-1000-8000-00805f9b34fb` | Weight Measurement |
| `00002a9e-0000-1000-8000-00805f9b34fb` | Weight Scale Feature |
| `00002a9f-0000-1000-8000-00805f9b34fb` | User Control Point |
| `00002aff-0000-1000-8000-00805f9b34fb` | (Unknown) |

## Architecture
The VeSync app uses a layered BLE architecture:
1. **Nordic BLE Library** (`no.nordicsemi.android.ble`) — Low-level BLE operations
2. **VeSync BLE SDK** (`com.vesync.lib.ble`) — Multi-device abstraction layer
3. **Device implementations** — `SensorDevice`, `HealthRateDevice`, `IdoBraceletDevice`, etc.
4. **Protocol-specific handlers** — `l80/b.java`, `l80/e.java` (scale BLE managers)

The scale uses `l80/b.java` which extends `i70.b` (base BLE manager) and implements `l80.a` (scale interface).

## BLE Connection Flow (Scale)
1. Connect to scale by MAC address
2. Discover services
3. Get service `0000ffa0`
4. Get characteristics `ffa1`, `ffa2`, `ffa3`, `ffa4`
5. Enable notifications on CCCD descriptors
6. Subscribe to `ffa2` for weight data
7. Write unit/tare commands to `ffa1`

## Third-Party Device Protocols
The VeSync app also integrates with:
| Protocol | Package | UUID Prefix |
|----------|---------|-------------|
| Ido Bracelet | `com.ido.ble` | `0000afXX` |
| QN (QingNiao) Scale | `com.qn.device` | `0000ffXX`, `0000abf1` |
| Jump Device | `JumpDevice` | `0000efe9` |

## Next Steps
1. **HCI snoop** to identify which UUID set the ESN00 specifically uses
2. The scale likely uses the FFA0 or FFE0 service for weight data
3. Body composition scales (if supported) use standard GATT profiles (181b/181d)
4. Tare/unit commands likely sent via `ffa1` characteristic
5. Compare with dev.to/hertzg writeup for partial protocol info

## Files Analyzed
- `p70/j.java` — Complete UUID constant interface (40+ UUIDs)
- `l80/b.java` — Scale BLE manager implementation
- `l80/e.java` — Secondary scale BLE manager
- `com/vesync/lib/ble/third/platform/device/SensorDevice.java` — Sensor device handler
- `com/vesync/lib/ble/third/platform/device/HealthRateDevice.java` — HR monitor
- `com/vesync/lib/ble/third/platform/device/IdoBraceletDevice.java` — Ido bracelet
- `com/vesync/lib/ble/third/platform/device/JumpDevice.java` — Jump rope
