# OpenGreenIoT Mobile — Build & Test Guide

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
| Rust | stable (1.75+) | `rustc --version` |
| cargo-ndk | latest | `cargo ndk --version` |

### Android Builds

| Tool | Version |
|------|---------|
| Android SDK | API 34 |
| Android NDK | 26.1.10909125 |
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
4. Adds iOS targets on macOS (aarch64-apple-ios, aarch64-apple-ios-sim)
5. Installs `cargo-ndk` for Android NDK integration
6. Installs `flutter_rust_bridge_codegen` v2.9.0
7. Sets up Android SDK components (API 34, NDK 26.1)
8. Creates Android emulator AVD (`opengreeniot_test`)
9. Runs `pod install` on macOS
10. Runs `flutter pub get` and generates FRB bindings

After setup, add Flutter to your PATH:

```bash
export PATH="$HOME/.flutter-sdk/bin:$PATH"
```

Add this to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) to persist it.

Verify the setup:

```bash
flutter doctor
rustc --version
cargo ndk --version
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
  aarch64-apple-ios-sim
```

### 3. Install Cargo Tools

```bash
cargo install cargo-ndk
cargo install flutter_rust_bridge_codegen@2.9.0
```

### 4. Android SDK

Install Android Studio or the command-line tools. Then:

```bash
sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34" "ndk;26.1.10909125"
```

Set `ANDROID_HOME`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
```

### 5. Project Dependencies

```bash
cd opengreeniot-mobile
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
flutter run --dart-define=OPENGREENIOT_MOCK=true

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

Current Flutter test files:
- `test/models/iot_device_test.dart` — IoTDevice model (5 tests)
- `test/models/device_characteristic_test.dart` — DeviceCharacteristic model (4 tests)
- `test/services/device_manager_test.dart` — DeviceManager service (7 tests)
- `test/widget_test.dart` — Root widget smoke test (1 test)

### Rust Tests

```bash
cd rust

# Run all tests
cargo test

# Run with output visible
cargo test -- --nocapture

# Run specific test module
cargo test protocol::profiles
cargo test api::device_api
cargo test codec::types
cargo test spec::parser

# Run a specific test
cargo test decode_standard_battery_level
```

Current Rust test modules:
- `api::device_api` — FFI API, DTOs, roundtrip encoding (13 tests)
- `api::mock_api` — Mock read/write (2 tests)
- `codec::types` — Binary encoding/decoding (7 tests)
- `protocol::generic` — GenericProtocol (6 tests)
- `protocol::registry` — ProtocolRegistry (4 tests)
- `protocol::profiles` — UUID normalization, lookup (10 tests)
- `protocol::profiles::battery` — Battery protocol (8 tests)
- `protocol::profiles::device_info` — Device info protocol (8 tests)
- `spec::parser` — YAML parsing (5 tests)

### Linting and Formatting

```bash
# Dart
flutter analyze                        # Static analysis
dart format --set-exit-if-changed .    # Check formatting
dart format .                          # Fix formatting

# Rust
cd rust
cargo clippy                           # Lint
cargo fmt -- --check                   # Check formatting
cargo fmt                              # Fix formatting
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
flutter run --dart-define=OPENGREENIOT_MOCK=true
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

### Android

- **Physical device**: Enable Developer Options → USB Debugging. Connect via
  USB.
- **Emulator**: The setup script creates an `opengreeniot_test` AVD.
  Emulators don't support real BLE — use mock mode.
- **BLE permissions**: The app requests `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`,
  and `ACCESS_FINE_LOCATION` at runtime. Location is required by Android for
  BLE scanning.

---

## CI

GitHub Actions runs on every push to `main` and on pull requests:

**Workflow**: `.github/workflows/ci.yml`

**Steps**:
1. Checkout code
2. Set up Flutter 3.24.x (stable)
3. `flutter pub get`
4. `flutter analyze` — static analysis
5. `flutter test --coverage` — unit tests with coverage
6. `dart format --set-exit-if-changed .` — formatting check

The CI runs on `ubuntu-latest`. Rust tests are not currently in CI but can be
run locally with `cd rust && cargo test`.

---

## Troubleshooting

### `flutter doctor` shows issues

Run `flutter doctor -v` for detailed output. Common fixes:
- Missing Android SDK: Install via Android Studio or `sdkmanager`
- Missing Xcode (macOS): Install from App Store
- Android licenses: `flutter doctor --android-licenses`

### Flutter can't find Rust library

If you get link errors referencing `opengreeniot_core`:
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
emulator -avd opengreeniot_test -verbose
```

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
flutter run --dart-define=OPENGREENIOT_MOCK=true
```

Hot reload after adding `--dart-define` won't work — you need a full restart.
