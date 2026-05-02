# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Platform scaffolds** — Android (`android/`) and iOS (`ios/`) folders are now
  committed. `flutter build apk` and `flutter build ios` work out of the box.
- **CI overhaul** — separate jobs for Flutter (analyze + test + format +
  Codecov), Rust (fmt + clippy + test), Android debug-APK smoke build, iOS
  simulator build on macOS, and Android emulator integration tests.
- **Test coverage** — reusable `FakeBleService` plus widget/screen tests for
  `ScanScreen`, `DeviceScreen`, `DeviceControlPanel`, `RawCharacteristicWidget`,
  a provider test for `deviceSpecsProvider`, and unit tests for `bytesToHex`,
  `normalizeUuid`, and `mapConnectionState`.
- **Integration tests** under `integration_test/` covering the mock scan →
  connect → discover flow and the error + retry path.
- `scripts/test.sh` — one-shot local CI mirror.
- `pubspec.lock` is now committed for reproducible app builds.
- `lib/core/hex.dart` — `bytesToHex` and `normalizeUuid` helpers (deduplicated
  from three call sites).
- **FRB wiring** — `flutter_rust_bridge` 2.9.0 bindings are generated and
  committed (`lib/src/rust/`, `rust/src/frb_generated.rs`). `RustLib.init()`
  runs at app startup; `MockBleService` now delegates read/write to
  `rust/src/api/mock_api.rs` with a Dart fallback when the native library
  isn't loaded. CI builds the host Rust lib before `flutter test` and checks
  the bindings are in sync with the Rust API (drift check).
- Lint additions in `analysis_options.yaml`: `cancel_subscriptions`,
  `close_sinks`, `unawaited_futures`.
- Standard Bluetooth profile controllers: Battery Service (0x180F) and
  Device Information Service (0x180A)
- Protocol error types module (`error.rs`) with `ProtocolError` and `SpecError`
- FFI API: `load_device_spec()`, `match_device_to_spec()` (returns
  `Vec<MatchResult>` with categorical match reasons), unified
  `encode_command()`/`decode_value()` that take optional `spec_yaml` and
  `service_uuid` (spec wins when both supplied), and
  `identify_standard_profiles()` for service-UUID discovery
- Protocol dispatcher (`protocol::dispatch::select_protocol`) routes
  encode/decode requests to either a YAML-driven `GenericProtocol` or a
  built-in standard profile, with content-hash spec caching
- Spec format gains `mock_default` per format field; the simulator
  consults it before the name-based heuristic
- Parse-time spec validation: rejects fixed-width fields with the wrong
  `length`, parameter `min`/`max` bounds outside the declared type,
  and inverted `min > max` bounds
- `#[serde(deny_unknown_fields)]` on every spec struct catches typos in
  YAML at parse time
- Mock simulator with smart default values per field type
- E2E architecture walkthrough documentation (`docs/WALKTHROUGH.md`)
- Build and test guide for Linux and macOS (`docs/BUILD_AND_TEST.md`)
- Expanded README with architecture diagram, setup instructions, and Rust core docs

### Fixed

- `MockBleService.subscribeCharacteristic` no longer leaks the periodic
  `Timer` when the subscriber cancels without disconnecting.
- `RealBleService` now caches discovered GATT services per device, eliminating
  a redundant round-trip on every read/write/subscribe. Cache is invalidated on
  disconnect.
- `deviceSpecsProvider` distinguishes "missing asset" (silent) from "malformed
  YAML" (logged), so real errors are no longer swallowed.
- UUID normalization now handles all-zero prefixes correctly (e.g. `000000f0`)
- Mutex lock recovery at FFI boundary (prevents panic on poisoned mutex)
- Overflow guard in codec field offset calculation
- Saturating cast for u64→i64 in DTO conversion

### Changed

- `MockBleService` deduplicates its two mock devices' service definitions into
  shared `_controlService` / `_batteryService` constants.
- `DeviceScreen` extracts a file-private `_CenteredProgress` widget used by the
  connecting/discovering states.
- Initial project structure
- BLE device scanning model (`IoTDevice`)
- Device characteristic model (`DeviceCharacteristic`)
- BLE service layer (`BleService`)
- Device manager for tracking discovered devices
- Scan screen UI scaffold
- Device screen UI scaffold
- Characteristic screen UI scaffold
- Unit tests for models and services
- CI pipeline with GitHub Actions
- Android BLE permissions in manifest
- iOS BLE usage descriptions in Info.plist
