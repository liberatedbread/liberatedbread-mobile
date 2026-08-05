# Liberated Bread Mobile — Architecture Walkthrough

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
  runApp(const ProviderScope(child: LiberatedBreadApp()));
}
```

`RustLib.init()` is wrapped in a try/catch so the app still runs when the
native library isn't bundled (e.g. test builds that skip cargokit);
`MockBleService` has a Dart fallback table that matches Rust's mock output.

### `lib/app.dart`

`LiberatedBreadApp` is a `StatelessWidget` that returns a `MaterialApp` with:
- Material Design 3 theming (Liberated Bread orange/blush, light + dark —
  see [BRANDING.md](BRANDING.md))
- Home screen: `HomeShell()`

### Navigation Flow

```
HomeShell ┬ Nearby → ScanScreen  → (tap device) → DeviceScreen
          ├ Saved  → SavedDevicesScreen → (tap device) → DeviceScreen
          └ Wi-Fi  → WifiScanScreen → (tap device) → details sheet
```

Characteristics render inline on `DeviceScreen` — there is no separate
per-characteristic screen. The scan screen's AppBar also pushes two settings
screens: `SpecPackSettingsScreen` (puzzle-piece icon) and `HaSettingsScreen`
(gear icon).

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
`LIBERATED_BREAD_MOCK=true` is set.

Four hardcoded mock devices, each advertising something different so demo mode
exercises every rung of the scan-time confidence ladder without hardware:
- **ACME_Living_Room** (-45) — advertises its service UUID (strong)
- **ACME_Bedroom** (-62) — recognisable by name alone
- **Airthings Wave Plus** (-58) — recognisable by company ID alone
- an unnamed device on a Xiaomi OUI (-78) — identifiable only by its address
  block, so it must be offered as a possibility rather than a claim

The first two have:
- Control Service (0x0000fff0) with Command (write) and Status (read+notify)
- Battery Service (0x0000180f) with Battery Level (read+notify)

The other two derive their GATT tree from their vendored spec.

The mock service simulates connection delays and RSSI jitter. Byte-level
logic (defaults, write-through state) delegates to Rust's `mock_api` via
flutter_rust_bridge when the native library is loaded; a small Dart fallback
table produces the same bytes when it isn't.

### Device Manager — `lib/services/device_manager.dart`

Simple in-memory registry for discovered devices. Provides sorted access
(by RSSI descending) and lookup by ID. Used by `ScanScreen` to maintain the
device list across scan cycles; the screen then re-ranks that list by what the
catalogue recognises (see `rankScannedDevices`).

### The rest of `lib/services/`, briefly

- `spec_codec.dart` — abstract codec interface; re-exports the FRB DTOs so
  widgets and tests never import generated bindings directly.
- `number_registry.dart` — binary search over the vendored IEEE address-block
  and Bluetooth SIG tables; names the maker of hardware in no catalogue.
- `network_scan_service.dart` / `real_network_scan_service.dart` /
  `mock_network_scan_service.dart` — local-network discovery over mDNS and
  SSDP, in the same abstract/real/mock shape as the BLE service.
- `real_spec_codec.dart` — production `SpecCodec`; a thin pass-through to the
  Rust FFI.
- `spec_pack_service.dart` — downloads and caches remote spec packs
  (same-origin-only, size-capped, codec-validated; see the README's
  "Remote spec packs" section).
- `ha_api_client.dart` — abstract Home Assistant `mobile_app` API
  (registration + webhook sensor pushes); the seam where MQTT or a two-way
  command channel would plug in later.
- `http_ha_api_client.dart` — the HTTP implementation: Bearer-token
  registration, then unauthenticated pushes to `/api/webhook/{id}`.
- `ha_sensor_forwarder.dart` — bridges decoded BLE readings to HA sensor
  updates; recovers dropped readings on failure and exposes forwarder health.
- `settings_store.dart` — minimal key/value persistence interface.
- `prefs_settings_store.dart` — `SharedPreferences`-backed store for
  non-secrets (e.g. the spec-pack URL).
- `secure_settings_store.dart` — platform keychain/keystore-backed store via
  `flutter_secure_storage`; the HA token and webhook id live here.

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
| `serviceUuids` | `List<String>` | Service UUIDs in the *advertisement* — not the discovered GATT tree |
| `companyIds` | `List<int>` | Bluetooth SIG company IDs from the manufacturer data |

Computed properties:
- `isNearby` — `rssi > -70`
- `displayName` — Falls back to `"Unknown ($id)"` if name is empty
- `macAddress` — the id when it is a hardware address, else null. Apple
  platforms substitute a per-host CoreBluetooth UUID, which carries no OUI and
  must never be read as one.
- `hasSameIdentity(other)` — whether two sightings say the same thing about
  *what* the device is. Excludes rssi, so spec matching runs once per device
  rather than once per advertisement.

Equality and `hashCode` are based on `id`.

### `NetworkDevice` — `lib/models/network_device.dart`

The Wi-Fi counterpart: host, name, hostname, port, mDNS service types, SSDP
search targets, TXT records, and which transports found it. Deliberately not
the same class as `IoTDevice` — a network device has no RSSI and no connectable
flag, and its address is a DHCP lease rather than a hardware identity, so
conflating them would mean a pile of fields null for one half of the app.

`advertisedMac` digs a MAC out of the TXT record when there is one, including
the EUI-64 form a Hue bridge publishes as `bridgeid` (the address with `FFFE`
spliced into the middle — truncating to the first twelve digits, the obvious
wrong move, yields an address that resolves to nothing).

### Hex display helpers — `lib/core/hex.dart`

There is no per-characteristic model wrapping raw values; widgets hold the raw
`List<int>` and format it with free functions from `lib/core/hex.dart`:
`bytesToHex` renders bytes as `"00 ff 0a"`, `asciiPreview` returns the value
as text when every byte is printable ASCII (else `null`), and `tryParseHex`
parses user-entered hex input tolerantly (`0x` prefixes, separators).

### HA models — `lib/models/ha_config.dart`, `lib/models/ha_sensor.dart`

`HaConfig` (server URL, token, webhook id, forwarding flag) and the sensor
payload models for Home Assistant companion mode.

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

`isMockMode` is a compile-time constant from `--dart-define=LIBERATED_BREAD_MOCK`.

### `deviceSpecsProvider` — `lib/providers/device_spec_provider.dart`

Loads device spec YAML strings from two merged sources: the specs bundled as
app assets (the fallback, keyed by asset path) and any remote spec packs the
user has installed (keyed `pack:<name>/<file>`, so keys can never collide).
Bundled specs always load even when no pack is installed; a pack failure never
removes a bundled spec.

Note: `AssetBundle` doesn't support directory listing, so bundled spec files
are enumerated explicitly in a hardcoded list — new bundled specs must be
added there (and to the `rust/tests/vendored_assets.rs` assertion). A missing
asset is skipped silently; malformed YAML is logged.

### `specCodecProvider` — `lib/providers/spec_codec_provider.dart`

Provides the `SpecCodec` (the `RealSpecCodec` Rust FFI in production);
overridden with a fake in tests, mirroring `bleServiceProvider`.

### `matchedDeviceSpecProvider` — `lib/providers/device_spec_match_provider.dart`

A family provider matching a connected device (name + discovered service
UUIDs) against every loaded spec through the Rust matcher. The family key
(`SpecMatchRequest`) has value equality so the cache survives widget rebuilds;
the result carries both the parsed DTO and the raw YAML (the codec takes
YAML).

### Spec-pack providers — `lib/providers/spec_pack_provider.dart`

`specPackServiceProvider` (the downloader/cache), `specPackUrlProvider` (the
manifest URL, persisted in `SharedPreferences`, defaulting to
`AppConstants.defaultSpecPackUrl`), `cachedSpecPacksProvider` (cached specs
for `deviceSpecsProvider` to merge), and `installedSpecPacksProvider` (pack
metadata for the settings screen).

### HA providers — `lib/providers/ha_provider.dart`

`settingsStoreProvider` (keychain-backed store), `haApiClientProvider`,
`haForwarderProvider`, and the `haConfigProvider` notifier that loads,
registers, and updates the persisted Home Assistant configuration.

---

## 5. Screens and Widgets

### HomeShell — `lib/screens/home_shell.dart`

The app's three top-level destinations, behind a bottom navigation bar:
**Nearby** (BLE scan), **Saved** (paired devices), **Wi-Fi** (local network
scan). An `IndexedStack` rather than a swapped child, because each tab owns a
scan in progress and a list of results — rebuilding those every time somebody
glances at another tab would throw away a scan they are in the middle of.

### ScanScreen — `lib/screens/scan_screen.dart`

The Nearby tab. Shows a list of discovered BLE devices.

**State**: `_deviceManager`, `_isScanning`, `_error`

**Behavior**:
1. User taps FAB → `_startScan()` calls `bleService.scan()`
2. Devices stream in, added to `DeviceManager`, UI rebuilds
3. Each device row shows name, RSSI, "Nearby" badge
4. When in mock mode, an "MOCK" chip appears in the AppBar
5. Tap a device → navigate to `DeviceScreen`

**Naming the unknown**: most of what a scan returns is in no catalogue.
`NumberRegistry` (`lib/services/number_registry.dart`) reads the vendored IEEE
address-block and Bluetooth SIG tables so a device with no name at all can still
be titled by its maker, and one that advertises capabilities can have them named
("Battery Service, Environmental Sensing") with vendor 128-bit UUIDs counted
rather than printed. The tables are held as sorted strings and binary-searched
in place — 50,000 entries parsed into a map would cost several megabytes of Dart
heap to answer a question asked a few dozen times per scan. Address lookups try
the longest block first; see `vendor/protocol-specs/registries/SOURCES.md` for
why, and for why a vendor name from an OUI is frequently the *chip* vendor.

**Ranking**: a scan in a populated building is mostly other people's earbuds,
so the list does not sort on signal strength alone. Each device's advertisement
— local name, service UUIDs, manufacturer-data company IDs, and (where the
platform exposes one) the MAC OUI — goes through `scanGuessProvider`, and
`rankScannedDevices` splits the result into a **Likely supported** section and
everything else.

The four signals are weighted, not pooled; `MatchConfidence` in
`rust/src/api/device_api.rs` is where that judgement lives, and both the scan
matcher and the post-connect `matchDeviceToSpec` go through the same core so
they cannot drift. A service UUID is near proof. A name prefix or company ID is
good evidence. A MAC OUI identifies a vendor rather than a product, so an
OUI-only match stays *out* of the promoted section and is labelled "Possibly
&lt;manufacturer&gt;" — never a device name. On Apple platforms CoreBluetooth
substitutes a per-host UUID for the address, so there is no OUI to read and
`IoTDevice.macAddress` returns null rather than treating the UUID's hex digits
as one.

Matching is keyed on device *identity* (`ScanIdentity`), not device id, so the
hundreds of advertisements one device emits during a scan resolve to a single
FFI call; only `SpecIdentityDto` — a few strings per spec — crosses the
boundary, not the parsed catalogue.

### SavedDevicesScreen — `lib/screens/saved_devices_screen.dart`

The Saved tab: devices the user has already paired with, newest first, each
with reconnect and forget. Previously a "History" section pinned to the bottom
of the scan screen, below however many strangers' earbuds the last scan turned
up — a device you have already set up is the one you come back to. A saved
record keeps only an id, a name and a last-seen stamp, so the id is run through
the IEEE registry for a vendor name the same way a scan result is.

### WifiScanScreen — `lib/screens/wifi_scan_screen.dart`

The Wi-Fi tab. Half the catalogue is hardware with no Bluetooth at all, which a
BLE scan can never see.

`RealNetworkScanService` asks over **both** mDNS/DNS-SD and SSDP, because they
do not overlap: modern local-first devices announce over mDNS only, while Wemo
and pre-2020 Hue bridges are SSDP-only. mDNS discovery goes through the generic
`_services._dns-sd._udp.local` enumeration rather than a fixed list, so it finds
hardware whose spec nobody has written yet. The two halves run concurrently and
fail independently — a network with IGMP snooping, or an iOS multicast
entitlement problem, should still return whatever the other found. A host
answering on both transports is merged by `NetworkScanCoalescer` into one row.

Matching goes through `match_network_device` in the Rust api, which shares
`MatchAxes` and therefore `MatchConfidence` with the BLE matcher — a badge means
the same thing on either tab. An mDNS service type or SSDP search target rates
Strong (vendor-specific identifiers the device volunteered); a `default_port` is
the network's OUI equivalent and only ever ranks, since port 80 says nothing
about who is listening. A spec declaring nothing about the network can never
match a host on it, so a BLE spec whose `local_name_prefix` happens to prefix an
mDNS instance name stays off this tab.

Two platform gotchas, both of which fail *silently*:

* iOS will not deliver an mDNS answer for a service type absent from
  `NSBonjourServices` in `Info.plist`.
* Android filters multicast frames out to save power unless the app can take a
  multicast lock, which needs `CHANGE_WIFI_MULTICAST_STATE`.

Both are pinned by `test/platform/`. A denied local-network permission also
looks exactly like an empty network from inside the app, so on Apple platforms
that case raises `LocalNetworkDeniedException` and gets its own guidance with a
settings link rather than a "no devices found" dead end.

### DeviceScreen — `lib/screens/device_screen.dart`

Connection and service discovery screen.

**State machine**: `connecting` → `discovering` → `ready` (plus `error`, and
`disconnected` when an established link drops)

**Behavior**:
1. `initState()` calls `_connect()` — connects and discovers services
2. While connecting: spinner + "Connecting..."
3. While discovering: spinner + "Discovering services..."
4. Ready: renders `DeviceControlPanel` with discovered services
5. Error: error message with retry option
6. `dispose()` disconnects from the device

### HaSettingsScreen — `lib/screens/ha_settings_screen.dart`

Home Assistant companion-mode setup and status. Unconfigured: URL +
long-lived-token form with live Tailscale remote-access hints. Registered:
connection status, forwarding toggle, and disconnect.

### SpecPackSettingsScreen — `lib/screens/spec_pack_settings_screen.dart`

Install and manage downloadable spec packs: an editable, validated manifest
URL, install/refresh with loading and success/error states, and the list of
installed packs with per-pack remove and clear-all.

### DeviceControlPanel — `lib/widgets/device_control_panel.dart`

Renders a list of services as expandable cards, and is where spec matching
meets the UI: it watches `matchedDeviceSpecProvider` for the connected
device's name + service UUIDs. Characteristics covered by a matched spec
render as `TypedCharacteristicWidget` (typed commands and decoded values);
everything else falls back to `RawCharacteristicWidget`. The raw browser
shows immediately and is replaced in place once a match resolves — there is
no separate characteristic screen.

### Typed control widgets — `lib/widgets/typed_*.dart`

`TypedCharacteristicWidget` composes `TypedCommandWidget` (buttons for fixed
commands, sliders for parameterized ones, straight from the spec's
`commands`) and `DecodedValueWidget` (decoded `format` fields, live-updating
on notify).

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
├── test_fixtures.rs    # #[cfg(test)] shared spec fixtures for unit tests
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
- **`ProtocolError`** — encoding/decoding/lookup failures:
  `CharacteristicNotFound`, `BufferTooShort`, `ParameterOutOfRange`,
  `UnsupportedCommandEncoding`, `NoProtocolForRequest`, and friends — see
  `rust/src/error.rs` for the full list.
- **`SpecError`** — spec parse and validation failures: `YamlParse` (wraps
  `serde_yaml::Error`) plus post-deserialize validation variants such as
  `FieldLengthMismatch`, `ParameterBoundsInverted`, and `DuplicateName` —
  again, `rust/src/error.rs` is the authority.

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

> **Heads up:** the import name is `serde_yaml`, but `rust/Cargo.toml` actually
> pulls in the maintained community fork `serde_yaml_ng`
> (`serde_yaml = { package = "serde_yaml_ng", ... }`). Upstream `serde_yaml`
> was archived in 2024. Don't be surprised that `cargo doc`/crates.io point at
> `serde_yaml_ng`.

`DeviceSpec::find_characteristic(uuid)` does case-insensitive lookup across
all services.

### Codec — `codec/types.rs`

**`DecodedValue`** enum: `Bool`, `Int(i64)`, `Uint(u64)`, `Bytes`, `String`

**Decoding** (`decode_field`, `decode_all_fields`):
- Reads bytes at the specified offset and length
- Interprets based on `ValueType`: bool, uint8, uint16 (LE), int8, int16 (LE),
  int32 (LE), uint32 (LE), bytes, string (UTF-8 with null trim)
- Returns `DecodedValues` — a newtype over `Vec<(String, DecodedValue)>` that
  preserves the spec's `format` order (which is the device's byte order); a
  `HashMap` would shuffle the readout on every process start

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
    fn decode_value(&self, char_uuid, bytes) -> Result<DecodedValues>;
    fn commands_for_characteristic(&self, char_uuid) -> Vec<String>;
    fn fields_for_characteristic(&self, char_uuid) -> Vec<String>;
}
```

The two `Vec<String>` listings come back in spec declaration order — that
order is the author's, and the trait docs forbid callers from sorting it.

Parameter types are elided above for readability — see
`rust/src/protocol/traits.rs` for the exact signatures (e.g. `encode_command`
takes `params: &HashMap<String, f64>` and returns
`Result<Vec<u8>, ProtocolError>`).

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
- On read: returns last written value, or generates a default
- Respects format field offsets and lengths

The default for a field is chosen in this order:
1. the field's explicit `mock_default` in the YAML spec (if present and in range
   for the field's type), then
2. a name-based heuristic (e.g. a field whose name contains `brightness` → 80,
   `battery`/`percent` → 85, `temp` → 2200, a `bool` field → on), then
3. zero.

So to make a mock device return a specific value, set `mock_default` on the
relevant format field in the spec — see `mock/simulator.rs` for the exact
heuristics and range rules.

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
  manufacturer_status: "abandoned"  # abandoned | active | shutdown | unsupported
  protocol: "ble"                   # ble | wifi | zigbee | zwave
  notes: "Optional notes"          # Optional
  identification:                   # Optional: for auto-matching
    local_name_prefix: "PREFIX_"   # Match by BLE advertised name
    service_uuids:                 # Match by advertised service UUIDs
      - "0000fff0-0000-1000-8000-00805f9b34fb"
    manufacturer_data:             # Match by advertisement company ID
      company_id: 961              # decimal; company_id_hex is for readers
      additional_company_ids: [89] # older firmware, rebadged models
    mac_prefixes: ["C4:7C:8D"]     # IEEE OUI — ranking hint ONLY, see below

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
                type: uint8           # bool | uint8 | uint16 | int8 | int16 | int32 | uint32 | bytes | string
                min: 0
                max: 100

        # For readable characteristics: decode format
        format:
          - offset: 0
            length: 1
            name: "field_name"
            type: "bool"              # Same types as parameters
            mock_default: true        # Optional: what the mock simulator returns
                                      # for unwritten reads (see §6)
```

### Supported Value Types

| Type | Size | Encoding |
|------|------|----------|
| `bool` | 1 byte | 0 = false, non-zero = true |
| `uint8` | 1 byte | Unsigned 0-255 |
| `uint16` | 2 bytes | Unsigned, little-endian |
| `int8` | 1 byte | Signed -128 to 127 |
| `int16` | 2 bytes | Signed, little-endian |
| `int32` | 4 bytes | Signed, little-endian |
| `uint32` | 4 bytes | Unsigned, little-endian |
| `bytes` | N bytes | Raw bytes |
| `string` | N bytes | UTF-8, null-terminated |

### Tolerated extension keys

Real protocol-docs specs carry more than the schema above, and the parser
accepts it rather than rejecting a working spec. Some extension keys are
parsed-and-preserved by name but not yet executed — `Command.setting_id` /
`.encoding` / `.payload`, `Parameter.allowed` / `.labels` / `.notes`,
`ParameterSet.color_order`, `Characteristic.encryption` / `.framing`,
`Service.notes`, `device.variants` / `.protobuf` / `.state_machine` /
`.version_fields`, and `identification.mdns_service_type` / `.ssid_prefix` /
`.default_port`. Anything else unrecognized at the top level or under
`identification` lands in a flattened `extensions` catch-all instead of
failing the parse (under `parameters`, every key that isn't the reserved
`color_order` is simply a parameter definition). The structs that drive
actual reads and writes keep `deny_unknown_fields`, so typos there still fail
loudly — see `rust/src/spec/types.rs` and `rust/tests/spec_tolerance.rs`.

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
- Spec matching in the UI: `DeviceControlPanel` watches
  `matchedDeviceSpecProvider` and renders typed controls (buttons, sliders,
  decoded values) for matched characteristics
- Remote spec packs, downloaded, validated, and cached on device
- Home Assistant companion mode, forwarding spec-decoded readings
- Persistence where it matters: the spec-pack cache on disk, the pack URL in
  `SharedPreferences`, and HA credentials in the platform keychain/keystore

### What's Pending
- **Persistence of discovered devices** — `DeviceManager` is in-memory only;
  the scan list resets on every app restart.
- **Parsed-but-not-executed spec extensions** — `encryption`/`framing`
  declarations, protobuf `setting_id` commands, and `json`/`tlv` payload
  encodings parse fine (see §7) but the codec doesn't execute them yet; the
  raw-byte fallback stays visible for those characteristics.
- **Non-BLE transports** — WiFi specs parse (their `mqtt_topics` /
  `http_endpoints` ride in the `extensions` bag), but the app speaks BLE
  only.
