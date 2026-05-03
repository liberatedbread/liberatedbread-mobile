# OpenGreenIoT Mobile — Architecture Walkthrough

This document is an end-to-end walkthrough of the codebase. It covers every
layer from the Flutter UI down to the Rust protocol core, explains how data
flows through the system, and documents the YAML device spec format.

## Table of Contents

1. [App Entry Point and Navigation](#1-app-entry-point-and-navigation)
2. [BLE Service Layer](#2-ble-service-layer)
3. [Models](#3-models)
4. [Providers (Riverpod)](#4-providers-riverpod)
5. [Screens and Widgets](#5-screens-and-widgets)
6. [Rust Core](#6-rust-core)
7. [Device Spec Format](#7-device-spec-format)
8. [Data Flow Examples](#8-data-flow-examples)
9. [Current Limitations and Next Steps](#9-current-limitations-and-next-steps)

---

## 1. App Entry Point and Navigation

### `lib/main.dart`

The app starts here. It initializes the Rust core via `RustLib.init()` and
wraps the root widget in Riverpod's `ProviderScope`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
  } catch (e, st) {
    debugPrint('RustLib.init failed ($e); falling back to Dart-side mock. $st');
  }
  runApp(const ProviderScope(child: OpenGreenIoTApp()));
}
```

`RustLib.init()` is wrapped in a try/catch so the app still runs when the
native library isn't bundled (e.g. test builds that skip cargokit);
`MockBleService` has a Dart fallback table that matches Rust's mock output.

### `lib/app.dart`

`OpenGreenIoTApp` is a `StatelessWidget` that returns a `MaterialApp` with:
- Material Design 3 theming (green color scheme, light + dark)
- Home screen: `ScanScreen()`

### Navigation Flow

```
ScanScreen → (tap device) → DeviceScreen → (tap characteristic) → CharacteristicScreen
```

All navigation uses standard `Navigator.push` with `MaterialPageRoute`.

---

## 2. BLE Service Layer

### Abstract Interface — `lib/services/ble_service.dart`

`BleService` is an abstract class defining the BLE contract. Both the real and
mock implementations conform to this interface:

| Method | Returns | Purpose |
|--------|---------|---------|
| `requestPermissions()` | `Future<bool>` | Request BLE/location permissions |
| `scan({Duration timeout})` | `Stream<IoTDevice>` | Scan for devices |
| `stopScan()` | `Future<void>` | Stop scanning |
| `connect(deviceId)` | `Future<void>` | Connect to a device |
| `disconnect(deviceId)` | `Future<void>` | Disconnect |
| `connectionState(deviceId)` | `Stream<BleConnectionState>` | Connection state stream |
| `discoverServices(deviceId)` | `Future<List<BleDiscoveredService>>` | Discover GATT services |
| `readCharacteristic(...)` | `Future<List<int>>` | Read a characteristic value |
| `writeCharacteristic(...)` | `Future<void>` | Write a characteristic value |
| `subscribeCharacteristic(...)` | `Stream<List<int>>` | Subscribe to notifications |

`BleConnectionState` enum: `disconnected`, `connecting`, `connected`,
`disconnecting`.

### Real Implementation — `lib/services/real_ble_service.dart`

`RealBleService` wraps the `flutter_blue_plus` library:

- **Permissions**: Uses `permission_handler` to request platform-specific
  permissions (Android: BLE scan + connect + location; iOS: Bluetooth).
- **Scanning**: Starts `FlutterBluePlus.startScan()`, maps scan results to
  `IoTDevice`, yields them on a stream. Stops on timeout or error.
- **Connection**: Calls `device.connect()` with 15-second timeout.
- **Service discovery**: Calls `device.discoverServices()`, maps to
  `BleDiscoveredService` models.
- **Read/Write**: Finds the right `BluetoothCharacteristic` by service + char
  UUID, calls `read()` or `write()`.
- **Notifications**: Calls `setNotifyValue(true)` and listens to
  `onValueReceived`.

### Mock Implementation — `lib/services/mock_ble_service.dart`

`MockBleService` simulates BLE without hardware. Used when
`OPENGREENIOT_MOCK=true` is set.

Two hardcoded mock devices:
- **ACME_Living_Room** (RSSI: -45)
- **ACME_Bedroom** (RSSI: -62)

Each has:
- Control Service (0x0000fff0) with Command (write) and Status (read+notify)
- Battery Service (0x0000180f) with Battery Level (read+notify)

The mock service simulates connection delays and RSSI jitter. Byte-level
logic (defaults, write-through state) delegates to Rust's `mock_api` via
flutter_rust_bridge when the native library is loaded; a small Dart fallback
table produces the same bytes when it isn't.

### Device Manager — `lib/services/device_manager.dart`

Simple in-memory registry for discovered devices. Provides sorted access
(by RSSI descending) and lookup by ID. Used by `ScanScreen` to maintain the
device list across scan cycles.

---

## 3. Models

### `IoTDevice` — `lib/models/iot_device.dart`

Represents a discovered BLE device:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | BLE device address (unique key) |
| `name` | `String` | Advertised device name |
| `rssi` | `int` | Signal strength in dBm |
| `isConnectable` | `bool` | Whether the device accepts connections |
| `discoveredAt` | `DateTime` | When the device was first seen |

Computed properties:
- `isNearby` — `rssi > -70`
- `displayName` — Falls back to `"Unknown ($id)"` if name is empty

Equality and `hashCode` are based on `id`.

### `DeviceCharacteristic` — `lib/models/device_characteristic.dart`

Represents a characteristic's current value:

| Field | Type | Description |
|-------|------|-------------|
| `uuid` | `String` | Characteristic UUID |
| `name` | `String?` | Human-readable name |
| `value` | `List<int>` | Raw bytes |
| `canRead/Write/Notify` | `bool` | Permissions |

Computed properties:
- `hexValue` — Bytes formatted as `"00 ff 0a"` or `"(empty)"`
- `stringValue` — Decoded as ASCII if all bytes are printable, else `null`

### `BleDiscoveredService` — `lib/models/ble_discovered_service.dart`

Immutable models decoupled from `flutter_blue_plus`:
- `BleDiscoveredService` — uuid + list of characteristics
- `BleDiscoveredCharacteristic` — uuid + permission flags

---

## 4. Providers (Riverpod)

### `bleServiceProvider` — `lib/providers/ble_provider.dart`

```dart
final bleServiceProvider = Provider<BleService>((ref) {
  return isMockMode ? MockBleService() : RealBleService();
});
```

`isMockMode` is a compile-time constant from `--dart-define=OPENGREENIOT_MOCK`.

### `deviceSpecsProvider` — `lib/providers/device_spec_provider.dart`

Loads YAML device spec files from assets:

```dart
final deviceSpecsProvider = FutureProvider<List<String>>((ref) async {
  // Loads assets/device_specs/example-bulb.yaml
  // Returns list of YAML strings
});
```

Note: `AssetBundle` doesn't support directory listing, so spec files are
enumerated explicitly.

---

## 5. Screens and Widgets

### ScanScreen — `lib/screens/scan_screen.dart`

The home screen. Shows a list of discovered BLE devices.

**State**: `_deviceManager`, `_isScanning`, `_error`

**Behavior**:
1. User taps FAB → `_startScan()` calls `bleService.scan()`
2. Devices stream in, added to `DeviceManager`, UI rebuilds
3. Each device row shows name, RSSI, "Nearby" badge
4. When in mock mode, an "MOCK" chip appears in the AppBar
5. Tap a device → navigate to `DeviceScreen`

### DeviceScreen — `lib/screens/device_screen.dart`

Connection and service discovery screen.

**State machine**: `connecting` → `discovering` → `ready` (or `error`)

**Behavior**:
1. `initState()` calls `_connect()` — connects and discovers services
2. While connecting: spinner + "Connecting..."
3. While discovering: spinner + "Discovering services..."
4. Ready: renders `DeviceControlPanel` with discovered services
5. Error: error message with retry option
6. `dispose()` disconnects from the device

### CharacteristicScreen — `lib/screens/characteristic_screen.dart`

Detail view for a single characteristic. Shows UUID, permission flags, and
raw value display. Navigated from `RawCharacteristicWidget`.

### DeviceControlPanel — `lib/widgets/device_control_panel.dart`

Renders a list of services as expandable cards. Each service shows its
characteristics using `RawCharacteristicWidget`.

Future: Once FRB is connected and specs are matched, this will render typed
controls (toggles, sliders, color pickers) instead of raw hex.

### RawCharacteristicWidget — `lib/widgets/raw_characteristic_widget.dart`

The raw GATT characteristic browser. Supports:

- **Read**: Reads value, displays as hex + ASCII
- **Write**: Hex input field, writes raw bytes
- **Notify**: Subscribes to notifications, updates value in real time
- Property badges: "Read", "Write", "Notify"
- Error display for failed operations

Auto-subscribes to notifications if the characteristic supports them.

---

## 6. Rust Core

All Rust code lives under `rust/src/`. It compiles as a static/dynamic
library for FFI via `flutter_rust_bridge`.

### Module Map

```
rust/src/
├── lib.rs              # Crate root — declares all modules
├── error.rs            # ProtocolError + SpecError enums
├── api/
│   ├── mod.rs
│   ├── device_api.rs   # FFI API: DTOs + public functions
│   └── mock_api.rs     # Mock device state management
├── codec/
│   ├── mod.rs
│   └── types.rs        # Binary encode/decode
├── mock/
│   ├── mod.rs
│   └── simulator.rs    # MockDeviceState with smart defaults
├── protocol/
│   ├── mod.rs
│   ├── traits.rs       # DeviceProtocol trait definition
│   ├── generic.rs      # YAML-driven GenericProtocol
│   ├── dispatch.rs     # select_protocol() + spec cache
│   └── profiles/
│       ├── mod.rs      # StandardProfile enum + UUID normalization
│       ├── battery.rs  # Battery Service (0x180F)
│       └── device_info.rs  # Device Information (0x180A)
└── spec/
    ├── mod.rs
    ├── types.rs        # DeviceSpec, Service, Characteristic, Command, etc.
    └── parser.rs       # YAML → DeviceSpec via serde
```

### Error Types — `error.rs`

Two error enums:
- **`ProtocolError`** — 10 variants for encoding/decoding failures
  (characteristic not found, buffer too short, parameter out of range, etc.)
- **`SpecError`** — Wraps `serde_yaml::Error` for parse failures

Both derive `thiserror::Error` for clean error messages.

### Spec System — `spec/`

**`spec/types.rs`** defines the Rust types matching the YAML schema:

- `DeviceSpec` — top level: device info + services
- `DeviceInfo` — name, manufacturer, status, protocol, identification
- `Service` — UUID, name, characteristics
- `Characteristic` — UUID, name, properties, commands, format
- `Command` — fixed `value` or `template` with parameters
- `TemplateElement` — `Byte(u8)` or `Param(String)` with custom deserializer
  for `"{param_name}"` syntax
- `FormatField` — offset, length, name, type (for decoding)

**`spec/parser.rs`** — `parse_device_spec(yaml) -> Result<DeviceSpec>` via
`serde_yaml`.

`DeviceSpec::find_characteristic(uuid)` does case-insensitive lookup across
all services.

### Codec — `codec/types.rs`

**`DecodedValue`** enum: `Bool`, `Int(i64)`, `Uint(u64)`, `Bytes`, `String`

**Decoding** (`decode_field`, `decode_all_fields`):
- Reads bytes at the specified offset and length
- Interprets based on `ValueType`: bool, uint8, uint16 (LE), int8, int16 (LE),
  bytes, string (UTF-8 with null trim)
- Returns `HashMap<String, DecodedValue>`

**Encoding** (`encode_command`):
- Fixed commands: returns the `value` bytes directly
- Template commands: expands `"{param}"` placeholders with validated values
- Validates min/max constraints on parameters
- Encodes based on parameter type (uint8, uint16 LE, int8, int16 LE)

### Protocol Layer — `protocol/`

**`traits.rs`** — The `DeviceProtocol` trait:

```rust
pub trait DeviceProtocol: Send + Sync {
    fn encode_command(&self, char_uuid, command_name, params) -> Result<Vec<u8>>;
    fn decode_value(&self, char_uuid, bytes) -> Result<HashMap<String, DecodedValue>>;
    fn commands_for_characteristic(&self, char_uuid) -> Vec<String>;
    fn fields_for_characteristic(&self, char_uuid) -> Vec<String>;
}
```

**`generic.rs`** — `GenericProtocol`: Implements `DeviceProtocol` driven
entirely by a `DeviceSpec`. Looks up characteristics by UUID (case-insensitive),
delegates encoding/decoding to the codec module.

**`dispatch.rs`** — `select_protocol(spec_yaml, service_uuid) -> Box<dyn
DeviceProtocol>`: the single dispatch point used by `api/device_api.rs`.
Picks `GenericProtocol` (when `spec_yaml` is supplied) or a
`StandardProfile`-backed controller (when `service_uuid` matches a known
profile). Spec wins over standard profile when both are supplied — pass
`spec_yaml: None` to force standard-profile dispatch. The dispatcher
memoizes parsed specs in `SPEC_CACHE: LazyLock<Mutex<HashMap<u64,
Arc<DeviceSpec>>>>` keyed by content hash, so repeat FFI calls with the
same YAML skip the parse and clone the inner `DeviceSpec` from the cached
`Arc` instead.

### Standard BLE Profiles — `protocol/profiles/`

**`profiles/mod.rs`**:
- `StandardProfile` enum: `BatteryService`, `DeviceInformation`
- `lookup(service_uuid) -> Option<StandardProfile>` — accepts short ("180f")
  or full UUIDs, case-insensitive
- `normalize_uuid()` — converts full 128-bit BT base UUIDs to short form

**`profiles/battery.rs`** — `BatteryServiceProtocol`:
- Battery Level (0x2A19): single uint8, 0-100%
- `decode_value` → `{"battery_percent": Uint(N)}`
- Read-only (encode returns `ProfileReadOnly` error)

**`profiles/device_info.rs`** — `DeviceInfoProtocol`:
- 7 characteristics (all read-only):
  - 0x2A29 Manufacturer Name, 0x2A24 Model Number, 0x2A25 Serial Number
  - 0x2A27 Hardware Rev, 0x2A26 Firmware Rev, 0x2A28 Software Rev
  - 0x2A23 System ID (8 bytes → colon-separated hex)
- Text characteristics: UTF-8 decode with null trim, hex fallback
- `decode_value` → `{"value": String("...")}`

### Mock Simulator — `mock/simulator.rs`

`MockDeviceState` generates realistic fake readings:
- Stores written values in memory
- On read: returns last written value, or generates smart defaults
  (brightness=80, battery=85, bool=on, temp=2200, etc.)
- Respects format field offsets and lengths

### FFI API — `api/device_api.rs`

DTO types for the Flutter↔Rust boundary (FRB-friendly, no references):
- `DeviceSpecDto`, `ServiceDto`, `CharacteristicDto`, `CommandDto`, etc.
- `DecodedValueDto` — uses `Option<i64>` instead of `u64` (FRB limitation)
  and surfaces the truthful value via `string_value` when the clamp fires
- `MatchResult` — `{spec, matched_by_name_prefix, matched_service_uuids}`
- `ProfileInfoDto`, `ProfileCharacteristicDto`

Public API functions:

| Function | Purpose |
|----------|---------|
| `load_device_spec(yaml)` | Parse YAML → `DeviceSpecDto` |
| `match_device_to_spec(specs, name, uuids)` | Return every matching spec with categorical reasons (`Vec<MatchResult>`) |
| `encode_command(spec_yaml, service_uuid, char, cmd, params)` | Encode command → bytes via `dispatch::select_protocol` |
| `decode_value(spec_yaml, service_uuid, char, bytes)` | Decode bytes → values via `dispatch::select_protocol` |
| `identify_standard_profiles(uuids)` | Identify standard BT profiles |

Both `encode_command` and `decode_value` take optional `spec_yaml` and
optional `service_uuid`; spec wins over standard profile when both are
supplied. To force standard-profile dispatch (e.g. read a Battery
characteristic), pass `spec_yaml: None` and the service UUID.

### Mock API — `api/mock_api.rs`

| Function | Purpose |
|----------|---------|
| `mock_reset()` | Clear all mock device state |
| `mock_read_characteristic(id, uuid, yaml)` | Simulated read |
| `mock_write_characteristic(id, uuid, value)` | Simulated write |

---

## 7. Device Spec Format

Device specs are YAML files in `assets/device_specs/`. Full schema:

```yaml
# Required: device metadata
device:
  name: "Device Name"
  manufacturer: "Manufacturer Name"
  manufacturer_status: "abandoned"  # abandoned | shutdown | unsupported
  protocol: "ble"                   # ble | wifi | zigbee | zwave
  notes: "Optional notes"          # Optional
  identification:                   # Optional: for auto-matching
    local_name_prefix: "PREFIX_"   # Match by BLE advertised name
    service_uuids:                 # Match by advertised service UUIDs
      - "0000fff0-0000-1000-8000-00805f9b34fb"

# Required: BLE services and characteristics
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Service Name"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Characteristic Name"
        properties: ["read", "write", "notify"]  # read | write | write_without_response | notify | indicate

        # For writable characteristics: commands
        commands:
          command_name:
            description: "Human-readable description"
            value: [0x01, 0x02]       # Fixed byte sequence
          parameterized_command:
            description: "Description"
            template: [0x02, "{param_name}"]   # "{...}" = parameter placeholder
            parameters:
              param_name:
                type: uint8           # bool | uint8 | uint16 | int8 | int16 | bytes | string
                min: 0
                max: 100

        # For readable characteristics: decode format
        format:
          - offset: 0
            length: 1
            name: "field_name"
            type: "bool"              # Same types as parameters
```

### Supported Value Types

| Type | Size | Encoding |
|------|------|----------|
| `bool` | 1 byte | 0 = false, non-zero = true |
| `uint8` | 1 byte | Unsigned 0-255 |
| `uint16` | 2 bytes | Unsigned, little-endian |
| `int8` | 1 byte | Signed -128 to 127 |
| `int16` | 2 bytes | Signed, little-endian |
| `bytes` | N bytes | Raw bytes |
| `string` | N bytes | UTF-8, null-terminated |

---

## 8. Data Flow Examples

### Flow 1: Scan → Connect → Read Battery Level

```
User taps "Scan" in ScanScreen
  → bleService.scan() starts
  → FlutterBluePlus.startScan() (real) or timer yields mock devices
  → IoTDevice objects added to DeviceManager
  → UI rebuilds with device list

User taps a device
  → Navigator.push → DeviceScreen(device)
  → bleService.connect(device.id)
  → bleService.discoverServices(device.id)
  → Services displayed in DeviceControlPanel

User taps "Read" on Battery Level characteristic
  → bleService.readCharacteristic(deviceId, "180f", "2a19")
  → Returns raw bytes, e.g. [85]
  → Rust: decode_value(spec_yaml: None, service_uuid: "180f",
                       char: "2a19", bytes: [85])
  → dispatch::select_protocol routes to BatteryServiceProtocol
  → Returns DecodedValueDto { name: "battery_percent", uint_value: 85 }
  → UI shows "85%"
```

### Flow 2: Write Command → Read Response

```
User selects "set_brightness" command with brightness=75
  → Rust: encode_command(spec_yaml: Some(yaml), service_uuid: None,
                         char: "fff1", cmd: "set_brightness",
                         params: {brightness: 75})
  → dispatch::select_protocol returns GenericProtocol(spec) (cached)
  → coerce_param validates: 0 ≤ 75 ≤ 100 ✓, fits in uint8 ✓
  → Encodes: [0x02, 0x4B]
  → Returns bytes to Flutter

Flutter writes bytes
  → bleService.writeCharacteristic(deviceId, "fff0", "fff1", [0x02, 0x4B])
  → BLE write to device

Device sends notification on Status characteristic
  → bleService.subscribeCharacteristic(deviceId, "fff0", "fff2")
  → Receives raw bytes, e.g. [1, 75, 255, 180, 50]
  → Rust: decode_value(spec_yaml: Some(yaml), service_uuid: None,
                       char: "fff2", bytes: [1, 75, 255, 180, 50])
  → Returns: power_state=true, brightness=75, red=255, green=180, blue=50
  → UI updates status display
```

### Flow 3: Standard Profile Identification

```
Device discovered with service UUIDs: ["180f", "180a", "fff0"]
  → Rust: identify_standard_profiles(["180f", "180a", "fff0"])
  → Returns:
    - ProfileInfoDto { service_uuid: "180f", profile_name: "Battery Service", ... }
    - ProfileInfoDto { service_uuid: "180a", profile_name: "Device Information", ... }
  → "fff0" is not a standard profile → omitted
  → UI can label known services and show typed controls
```

---

## 9. Current Limitations and Next Steps

### What's Working
- Complete Rust protocol system (spec parsing, codec, profiles)
- Flutter BLE scanning, connection, service discovery, read/write/notify
- Mock mode with two simulated devices, driven by the Rust simulator
- Standard BLE profile decoding (Battery, Device Info)
- FRB bridge wired end-to-end: `RustLib.init()` at startup,
  `MockBleService` delegates to `rust/src/api/mock_api.rs`

### What's Pending
- **Typed control widgets** — Currently shows raw hex. The UI will render
  toggles, sliders, color pickers based on matched device specs.
- **Device spec matching in UI** — Specs are loaded but not yet matched
  against discovered devices.
- **Persistence** — No local storage for discovered devices or specs.
