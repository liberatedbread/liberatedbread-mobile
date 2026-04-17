# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Standard Bluetooth profile controllers: Battery Service (0x180F) and
  Device Information Service (0x180A)
- Protocol error types module (`error.rs`) with `ProtocolError` and `SpecError`
- Protocol registry (`registry.rs`) for routing specs and UUIDs to protocols
- Middleware skeleton (`middleware.rs`) with `PassthroughMiddleware`
- FFI API: `identify_standard_profiles()` and `decode_standard_profile_value()`
- Mock simulator with smart default values per field type
- E2E architecture walkthrough documentation (`docs/WALKTHROUGH.md`)
- Build and test guide for Linux and macOS (`docs/BUILD_AND_TEST.md`)
- Expanded README with architecture diagram, setup instructions, and Rust core docs

### Fixed

- UUID normalization now handles all-zero prefixes correctly (e.g. `000000f0`)
- Mutex lock recovery at FFI boundary (prevents panic on poisoned mutex)
- Overflow guard in codec field offset calculation
- Saturating cast for u64→i64 in DTO conversion

### Changed

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
