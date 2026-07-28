# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No tagged release has been cut yet. Everything below is work toward the first
`0.1.0` release; once it ships, these entries move under a dated `## [0.1.0]`
heading.

### Added

- **Liberated Bread rebrand** — new Material 3 theme and palette
  (`LiberatedBreadApp` / `LiberatedBreadTheme`), regenerated platform icons, a
  `tool/branding/` pipeline (`brand.json` + `generate_icons.mjs`),
  `docs/BRANDING.md`, and `test/core/brand_test.dart` contrast checks so a
  palette change that breaks WCAG contrast fails CI.
- **E2E screenshot walkthrough** — `scripts/e2e-walkthrough.sh` +
  `scripts/e2e_shot_server.py` drive
  `integration_test/e2e_walkthrough_test.dart` through the whole app on the
  iOS Simulator, snapshotting each step; tagged `e2e` in `dart_test.yaml` and
  excluded from CI's emulator job via `--exclude-tags=e2e`.
- **Remote spec packs** — download a JSON-manifest pack of device specs at
  runtime (same-origin-only, size-capped, validated through the Rust codec
  before install): `SpecPackService`, `spec_pack_provider`, and
  `SpecPackSettingsScreen`, plus a `SettingsStore` abstraction with
  `PrefsSettingsStore` and new `http`/`path_provider`/`shared_preferences`
  dependencies.
- **Home Assistant companion mode** — register with HA's native `mobile_app`
  API and forward spec-decoded BLE readings as sensor entities: HA
  models/services/providers and `HaSettingsScreen`, `ha_url` +
  `ha_sensor_mapping` helpers, a `TailscaleSuggestionCard` with remote-access
  hints, and secure keychain/keystore token storage via
  `flutter_secure_storage` (`secure_settings_store.dart`).
- **Spec-driven typed control UI** — matched device specs render buttons,
  sliders, and decoded values instead of raw hex:
  `typed_characteristic_widget`, `typed_command_widget`,
  `decoded_value_widget`, backed by `device_spec_match_provider`,
  `spec_codec_provider`, and `real_spec_codec`; plus cargokit native-build
  wiring so `flutter build` compiles the Rust crate on every platform.
- `scripts/run-ios-device.sh`, `.github/workflows/ios-adhoc.yml`, and
  `docs/ios-from-linux.md` — build and run on a physical iPhone: locally from
  a Mac (`--list`/`--device`), or as an ad-hoc IPA built in CI for Linux-bound
  developers.
- `scripts/run-android.sh` and `scripts/run-ios.sh` — build, boot the
  emulator/simulator if needed, install, and run.
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
- `scripts/run-remote-mac.sh` — build and run on an iPhone from Linux via a
  remote Mac over SSH: rsyncs the tree, launches `flutter run` remotely, and
  auto-hot-reloads on every local save (docs/ios-from-linux.md Option C).
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
- `#[serde(deny_unknown_fields)]` on the protocol-execution spec structs
  (`DeviceInfo`, `Service`, `Characteristic`, `Command`, `Parameter`,
  `FormatField`) catches typos in YAML at parse time; `DeviceSpec`,
  `Identification`, and `ParameterSet` instead sweep unrecognized keys into an
  `extensions` catch-all (see the Changed entry on spec tolerance)
- Mock simulator with smart default values per field type
- E2E architecture walkthrough documentation (`docs/WALKTHROUGH.md`)
- Build and test guide for Linux and macOS (`docs/BUILD_AND_TEST.md`)
- Expanded README with architecture diagram, setup instructions, and Rust core docs
- Initial app scaffold: project structure; the `IoTDevice` and
  `BleDiscoveredService` models; the `BleService` layer and device manager; the
  scan and device screens; and Android BLE manifest permissions plus
  iOS `Info.plist` usage descriptions

### Fixed

- CI now installs the Android NDK the build actually uses
  (`FLUTTER_NDK_VERSION` pinned to 23.1.7779620 — Flutter 3.24.5 hardcodes it;
  installing anything else just made cargokit download this one mid-build),
  and the emulator job's disk-cleanup `rm -rf` on SDK paths is guarded against
  an unset `ANDROID_SDK_ROOT`.
- `HaSensorForwarder` recovers dropped readings when a push to Home Assistant
  fails, instead of reporting phantom success.
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

- Spec parsing is now tolerant of real-world protocol-docs specs: `DeviceSpec`,
  `Identification`, and `ParameterSet` dropped `deny_unknown_fields` in favor
  of a flattened `extensions` catch-all, so WiFi specs and vendor extension
  blocks parse instead of being rejected (`rust/tests/spec_tolerance.rs`
  documents the intent with vendored real specs).
- `scripts/test.sh` now mirrors CI's FRB binding drift check locally (skipped
  with a warning when the pinned codegen isn't installed).
- Migrated from the archived `serde_yaml` crate to the maintained
  `serde_yaml_ng` fork (imported under the same name via a Cargo rename).
- `MockBleService` deduplicates its two mock devices' service definitions into
  shared `_controlService` / `_batteryService` constants.
- `DeviceScreen` extracts a file-private `_CenteredProgress` widget used by the
  connecting/discovering states.
