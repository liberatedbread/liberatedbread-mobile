# Liberated Bread Mobile — Build & Test Guide

Step-by-step instructions for setting up, building, running, and testing the
app on **Linux** and **macOS**.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Automated Setup](#automated-setup)
3. [Manual Setup](#manual-setup)
4. [Building](#building)
5. [Running the App](#running-the-app)
6. [Testing](#testing)
7. [Mock Mode](#mock-mode)
8. [Platform-Specific Notes](#platform-specific-notes)
9. [CI](#ci)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required on All Platforms

| Tool | Version | How to Check |
|------|---------|-------------|
| Git | any | `git --version` |
| Flutter | 3.24+ (stable) | `flutter --version` |
| Rust | stable (1.82+) | `rustc --version` |

No `cargo-ndk` needed: cargokit (the flutter_rust_bridge native-build plugin)
drives the NDK itself during `flutter build`.

### Android Builds

| Tool | Version |
|------|---------|
| Android SDK | API 34 |
| Android NDK | 23.1.7779620 (Flutter 3.24.5's `flutter.ndkVersion`) |
| Android SDK Build-Tools | 34.0.0 |
| Java (for Gradle) | 17+ |

### macOS Only (iOS Builds)

| Tool | Version |
|------|---------|
| Xcode | 15+ |
| CocoaPods | latest |
| Xcode Command Line Tools | `xcode-select --install` |

---

## Automated Setup

The setup script handles everything. It's idempotent — safe to run multiple
times:

```bash
./scripts/setup.sh
```

What it does:
1. Installs Flutter SDK 3.24.5 to `~/.flutter-sdk`
2. Installs Rust via rustup (if not already installed)
3. Adds Android cross-compilation targets (aarch64, armv7, x86_64, i686)
4. Adds iOS targets on macOS (aarch64-apple-ios, aarch64-apple-ios-sim,
   x86_64-apple-ios)
5. Installs `flutter_rust_bridge_codegen` v2.9.0
6. Sets up Android SDK components (API 34, NDK 23.1.7779620)
7. Creates Android emulator AVD (`liberated_bread_test`)
8. Runs `pod install` on macOS
9. Runs `flutter pub get` and generates FRB bindings

After setup, add Flutter to your PATH:

```bash
export PATH="$HOME/.flutter-sdk/bin:$PATH"
```

Append it to your shell profile so it persists across new terminals, e.g.:

```bash
echo 'export PATH="$HOME/.flutter-sdk/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
```

Verify the setup:

```bash
flutter doctor
rustc --version
```

---

## Manual Setup

If you prefer to install tools yourself or already have some of them:

### 1. Install Flutter

Download from https://docs.flutter.dev/get-started/install or use the setup
script. Ensure `flutter` is on your PATH.

```bash
flutter --version    # Should show 3.24.x
flutter doctor       # Check for issues
```

### 2. Install Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"

# Add Android targets
rustup target add \
  aarch64-linux-android \
  armv7-linux-androideabi \
  x86_64-linux-android \
  i686-linux-android

# macOS: add iOS targets
rustup target add \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios
```

### 3. Install Cargo Tools

```bash
cargo install --locked flutter_rust_bridge_codegen@2.9.0
```

### 4. Android SDK

Install Android Studio or the command-line tools. Then:

```bash
sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34" "ndk;23.1.7779620"
```

Set `ANDROID_HOME`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
```

### 5. Project Dependencies

```bash
cd liberatedbread-mobile
flutter pub get
```

### 6. macOS: Xcode and CocoaPods

```bash
xcode-select --install
sudo gem install cocoapods
cd ios && pod install && cd ..
```

---

## Building

### Get Dependencies

```bash
flutter pub get
```

### Generate FRB Bindings (when Rust API changes)

```bash
flutter_rust_bridge_codegen generate
```

This reads `flutter_rust_bridge.yaml` and generates Dart bindings in
`lib/src/rust/` from the Rust code in `rust/src/api/`.

`lib/src/rust/` and `rust/src/frb_generated.rs` are **generated code** — don't
hand-edit them. Change the Rust API in `rust/src/api/`, then re-run the codegen.
Both files are committed, and CI fails if they drift from the Rust API.

### Build for Android

```bash
flutter build apk           # Release APK
flutter build apk --debug   # Debug APK
flutter build appbundle      # AAB for Play Store
```

### Build for iOS (macOS only)

```bash
flutter build ios            # Release
flutter build ios --debug    # Debug
```

### Build Rust Only (for testing)

```bash
cd rust
cargo build
cargo build --release
```

---

## Running the App

### Using the Run Script

```bash
# Run on connected device or emulator
./scripts/run.sh

# Run with mock BLE devices (no hardware needed)
./scripts/run.sh --mock
```

The run script:
- Checks for Flutter on PATH
- Runs `flutter pub get` if needed
- Finds a connected device or launches the Android emulator
- Waits for the emulator to boot (up to 120 seconds)
- Runs `flutter run` with appropriate flags

### Manual Run

```bash
# Real BLE mode (requires physical device with BLE)
flutter run

# Mock mode
flutter run --dart-define=LIBERATED_BREAD_MOCK=true

# Specify device
flutter run -d <device-id>

# Release mode
flutter run --release
```

### List Available Devices

```bash
flutter devices
```

---

## Testing

### Flutter Tests

```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/models/iot_device_test.dart

# Run tests in a directory
flutter test test/models/

# Run with coverage
flutter test --coverage

# View coverage report (requires lcov)
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

Flutter tests live under `test/`, mirroring `lib/`: `test/core`,
`test/models`, `test/providers`, `test/screens`, `test/services`, and
`test/widgets`, plus shared scaffolding in `test/fakes` (fake BLE service, HA
client, spec codec, pack service, in-memory settings store) and
`test/helpers` (the host Rust library loader). Browse `test/` for the current
inventory — the suite grows with every feature, and any list here would be
stale by the next PR.

Two callouts worth knowing about:
- `test/services/mock_ble_service_rust_test.dart` and
  `test/services/real_spec_codec_test.dart` exercise the real FRB path, so
  they need the host Rust library (next section) and self-skip when it isn't
  built.
- `test/core/brand_test.dart` fails when `lib/core/theme.dart` and
  `tool/branding/brand.json` drift apart (see [BRANDING.md](BRANDING.md)).

Integration tests under `integration_test/` need a connected device or emulator:
- `integration_test/mock_flow_test.dart` — scan → connect → discover
- `integration_test/error_flow_test.dart` — error state + retry
- `integration_test/e2e_walkthrough_test.dart` — scripted screenshot
  walkthrough, tagged `e2e` (see below)

### FRB-backed tests

`test/services/mock_ble_service_rust_test.dart` exercises the Rust mock API
through flutter_rust_bridge. Unlike a normal `flutter test`, the host-target
Rust library has to be built and discoverable at runtime — `flutter test` runs
on your machine, not a device, so it dynamically loads the desktop build of the
Rust core. From the repo root:

```bash
(cd rust && cargo build)
LD_LIBRARY_PATH=$PWD/rust/target/debug flutter test test/services/mock_ble_service_rust_test.dart
```

On macOS, `DYLD_FALLBACK_LIBRARY_PATH` does **not** work: the Flutter SDK's
`dart` binary uses the hardened runtime, and the loader strips `DYLD_*` from
such processes. Instead, `test/helpers/host_rust_lib.dart` opens
`rust/target/debug/<lib>` (then `release/`) by relative path, or the explicit
path in `LIBERATED_BREAD_RUST_LIB` — so on macOS just building the crate is
enough.

`scripts/test.sh` wires this automatically. If the library fails to load the
tests self-skip via `markTestSkipped` so CI on fresh clones doesn't see a hard
failure.

### E2E screenshot walkthrough

`integration_test/e2e_walkthrough_test.dart` drives the real app in mock mode
through the scan → connect → control flows and snapshots every step as a PNG.
Screenshots are taken host-side: the test asks a small HTTP server
(`scripts/e2e_shot_server.py`) on `127.0.0.1` to run `xcrun simctl io
screenshot`.

```bash
./scripts/e2e-walkthrough.sh                # boots a simulator, shots → ./e2e-shots
./scripts/e2e-walkthrough.sh --udid <UDID> --out ~/shots
```

macOS + iOS Simulator only: the simulator shares the host's network, so
`127.0.0.1` reaches the shot server. On the Android emulator `127.0.0.1` is
the emulator itself — which is why the test is tagged `e2e` in
`dart_test.yaml` and CI's emulator job runs with `--exclude-tags=e2e`.

### Rust Tests

```bash
cd rust

# Run all tests
cargo test

# Run with output visible
cargo test -- --nocapture

# Run specific test module
cargo test protocol::profiles
cargo test protocol::dispatch
cargo test api::device_api
cargo test codec::types
cargo test spec::parser

# Run a specific test
cargo test decode_via_standard_battery_profile
```

Current Rust test modules:
- `api::device_api` — FFI API, DTOs, roundtrip encoding, match results
- `api::mock_api` — Mock read/write
- `codec::types` — Binary encoding/decoding, typed parameter coercion
- `mock::simulator` — MockDeviceState, `mock_default` lookup
- `protocol::dispatch` — `select_protocol` routing + spec cache
- `protocol::generic` — GenericProtocol
- `protocol::profiles` — UUID normalization (Cow), lookup
- `protocol::profiles::battery` — Battery protocol
- `protocol::profiles::device_info` — Device info protocol
- `spec::parser` — YAML parsing + post-deserialize validation

Plus integration tests under `rust/tests/`:
- `spec_tolerance.rs` — parses the real protocol-docs specs vendored under
  `rust/tests/specs/`, proving vendor extension blocks and WiFi specs are
  tolerated rather than rejected by `deny_unknown_fields`
- `vendored_assets.rs` — asserts every bundled spec in `assets/device_specs/`
  parses through the real parser, and that the bundled set matches its
  expected file list (update it when adding a bundled spec)

### Linting and Formatting

```bash
# Dart
flutter analyze --fatal-infos          # Static analysis (CI treats infos as fatal)
dart format --set-exit-if-changed .    # Check formatting
dart format .                          # Fix formatting

# Rust
cd rust
cargo clippy --all-targets --all-features -- -D warnings   # Lint (as CI runs it)
cargo fmt --all -- --check             # Check formatting
cargo fmt --all                        # Fix formatting
```

---

## Mock Mode

Mock mode simulates BLE devices without requiring hardware. This is useful
for:
- Development on machines without BLE
- Testing on the Android emulator (emulators don't have real BLE)
- Demoing the app without physical IoT devices
- CI/CD pipelines

### What Mock Mode Provides

Two simulated devices:
- **ACME_Living_Room** (strong signal, RSSI -45)
- **ACME_Bedroom** (moderate signal, RSSI -62)

Each device has:
- **Control Service** (0x0000fff0)
  - Command characteristic (write)
  - Status characteristic (read + notify)
- **Battery Service** (0x0000180f)
  - Battery Level characteristic (read + notify)

### How to Use

```bash
./scripts/run.sh --mock
```

Or manually:

```bash
flutter run --dart-define=LIBERATED_BREAD_MOCK=true
```

### What to Expect

1. **Scan screen**: Two mock devices appear with slight RSSI jitter
2. **Connect**: Simulated connection with brief delay
3. **Service discovery**: Shows Control Service and Battery Service
4. **Read**: Returns default values (brightness=80, battery=85, power=on)
5. **Write**: Values are stored in memory; subsequent reads return written values
6. **Notify**: Simulated notification stream

---

## Platform-Specific Notes

### Linux

- **BLE permissions**: Real BLE scanning may require root access or adding
  your user to the `bluetooth` group:
  ```bash
  sudo usermod -a -G bluetooth $USER
  # Log out and back in
  ```
- **Linux desktop app**: Not currently configured (the app targets
  Android/iOS mobile). Use an Android device or emulator.
- **Android emulator**: Requires KVM for hardware acceleration:
  ```bash
  sudo apt install qemu-kvm
  sudo adduser $USER kvm
  ```

### macOS

- **Xcode Command Line Tools**: Required even for Android-only development
  (Flutter uses them for tooling):
  ```bash
  xcode-select --install
  ```
- **CocoaPods**: Required for iOS builds:
  ```bash
  sudo gem install cocoapods
  cd ios && pod install
  ```
- **Apple Silicon**: The setup script auto-detects ARM64 and downloads the
  correct Flutter SDK.
- **iOS simulator**: Has simulated BLE support — you can test basic flows.
  For full BLE testing, use a physical device.
- **Other scaffolds**: `macos/` and `web/` are committed alongside `android/`
  and `ios/` (the branding pipeline generates icons for them too), but the
  supported app targets are Android and iOS.

### Android

- **Physical device**: Enable Developer Options → USB Debugging. Connect via
  USB.
- **Emulator**: The setup script creates an `liberated_bread_test` AVD.
  Emulators don't support real BLE — use mock mode.
- **BLE permissions**: The app requests `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`,
  and `ACCESS_FINE_LOCATION` at runtime. Location is required by Android for
  BLE scanning.

---

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and
every pull request. Five jobs:

| Job | Runner | What it does |
|-----|--------|--------------|
| `flutter` | ubuntu-latest | `dart format --set-exit-if-changed`, `flutter analyze --fatal-infos`, builds the host Rust lib, checks the FRB bindings haven't drifted from `rust/src/api/`, `flutter test --coverage`, upload coverage to Codecov |
| `rust` | ubuntu-latest | `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --all-features` |
| `android-build` | ubuntu-latest | `flutter build apk --debug --dart-define=LIBERATED_BREAD_MOCK=true`; uploads the APK artifact |
| `android-integration` | ubuntu-latest (API 34 emulator) | warms the Gradle/cargokit caches with an APK build, frees runner disk, then `flutter test integration_test --exclude-tags=e2e --timeout 1200s --dart-define=LIBERATED_BREAD_MOCK=true` on the emulator |
| `ios-build` | macos-latest | `flutter build ios --debug --no-codesign --simulator --dart-define=LIBERATED_BREAD_MOCK=true` |

Caches: Flutter SDK, `~/.pub-cache`, `.dart_tool`, and `rust/target/` are
cached across runs. The quick checks run first; the native build jobs wait for
them to pass before spending runner time on the slower platform builds (fail
fast on lint/test).

### Running CI locally

`scripts/test.sh` mirrors the `flutter` and `rust` jobs, including the FRB
binding drift check (skipped with a warning when the pinned codegen isn't
installed):

```bash
./scripts/test.sh
```

Exits non-zero on the first failure.

### Codecov

Coverage uploads use `codecov/codecov-action@v4`. Set a `CODECOV_TOKEN` repo
secret if your fork is private; public repos don't need one.

---

## Troubleshooting

### `flutter doctor` shows issues

Run `flutter doctor -v` for detailed output. Common fixes:
- Missing Android SDK: Install via Android Studio or `sdkmanager`
- Missing Xcode (macOS): Install from App Store
- Android licenses: `flutter doctor --android-licenses`

### Flutter can't find Rust library

If you get link errors referencing `liberated_bread_core`:
1. Ensure Rust is installed: `rustc --version`
2. Run `flutter_rust_bridge_codegen generate`
3. Run `flutter clean && flutter pub get`

### Android emulator won't start

```bash
# Check if KVM is available (Linux)
ls /dev/kvm

# List available AVDs
emulator -list-avds

# Launch manually with verbose output
emulator -avd liberated_bread_test -verbose
```

If `liberated_bread_test` isn't in the `-list-avds` output, it hasn't been created
yet — run `./scripts/setup.sh` (which creates it) or make your own AVD in
Android Studio.

### BLE permissions denied on Android

Make sure the app has location and Bluetooth permissions. On Android 12+, the
app requests `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`. On older versions, it
needs `ACCESS_FINE_LOCATION`.

### `cargo test` fails

```bash
cd rust
cargo clean
cargo test
```

If you see linker errors, ensure all Rust targets are installed:
```bash
rustup target list --installed
```

### Mock mode not activating

The mock flag is a compile-time constant. You must pass it at build time:
```bash
flutter run --dart-define=LIBERATED_BREAD_MOCK=true
```

Hot reload after adding `--dart-define` won't work — you need a full restart.
