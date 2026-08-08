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
| Android SDK | API 36 — the pinned Flutter's `flutter.compileSdkVersion` |
| Android NDK | CI's `FLUTTER_NDK_VERSION` — the pinned Flutter's `flutter.ndkVersion` |
| Android SDK Build-Tools | 34.0.0 — AGP 8.6's default; a newer one only adds a download |
| Java (for Gradle) | 17+ |

The emulator is a separate axis: it boots API 34 (see the CI table below), and
nothing requires it to match the compile SDK.

Run `./scripts/ci-versions.sh` for the values CI is on right now; `./scripts/setup.sh`
installs exactly those.

### macOS Only (iOS Builds)

| Tool | Version |
|------|---------|
| Xcode | 15+ |
| CocoaPods | latest |
| Xcode Command Line Tools | `xcode-select --install` |

### Linux Desktop Builds

Only needed if you want to run the app on your Linux desktop (see
[Linux desktop](#linux-desktop) below). Flutter's standard Linux toolchain plus
one extra for secure storage:

```bash
sudo apt-get update && sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev
# optional: run headlessly (no display), the way CI does
sudo apt-get install -y xvfb
```

| Package | Why |
|---------|-----|
| `clang`, `cmake`, `ninja-build`, `pkg-config` | The Linux desktop build system |
| `libgtk-3-dev` | The GTK 3 shell the runner in `linux/` is written against |
| `liblzma-dev` | Needed transitively to link against GTK |
| `libsecret-1-dev` | `flutter_secure_storage_linux` — Home Assistant token storage |
| `libjsoncpp-dev` | Pulled in by the CMake/plugin toolchain |
| `xvfb` | Virtual X server, for running without a display |

Check it worked with `pkg-config --exists gtk+-3.0 && echo ok`, or just run
`./scripts/run-linux.sh` — it verifies each of these up front and names the
missing package rather than failing deep inside CMake.

---

## Automated Setup

The setup script handles everything. It's idempotent — safe to run multiple
times:

```bash
./scripts/setup.sh
```

What it does:
1. Installs the Flutter SDK to `~/.flutter-sdk`
2. Installs Rust via rustup (if not already installed)
3. Adds Android cross-compilation targets (aarch64, armv7, x86_64, i686)
4. Adds iOS targets on macOS (aarch64-apple-ios, aarch64-apple-ios-sim,
   x86_64-apple-ios)
5. Installs `flutter_rust_bridge_codegen`
6. Installs the Linux desktop toolchain via apt (GTK 3, clang/cmake/ninja,
   `libsecret`, Xvfb) — Linux only, skipped on non-apt distros with the list
   printed so you can install the equivalents
7. Sets up Android SDK components (platform, build-tools, NDK)
8. Installs the emulator and system image and creates the
   `liberated_bread_test` AVD — same image and device profile CI boots
9. Runs `pod install` on macOS
10. Runs `flutter pub get` and generates FRB bindings

### Where the versions come from

None of the above are pinned in the setup script.
`scripts/ci-versions.sh` reads them out of `.github/workflows/ci.yml` — the
Flutter version, NDK, Android API and build-tools, the FRB codegen pin, the
rustup target lists, the apt package list, and the emulator's API level,
system image target/arch and device profile. Bumping CI moves every dev
environment with it. To see what your environment will use:

```bash
./scripts/ci-versions.sh
```

Each value has a fallback used only if the workflow can't be parsed, and a
miss is reported on stderr. If you restructure how CI declares one of these,
re-run the command above and confirm the values still match the workflow.

Two things are *not* readable from CI, because no version appears there, and
so remain pinned by hand: the Android command-line tools build number (CI uses
`android-actions/setup-android`, which resolves "latest" itself) and the Rust
toolchain (`dtolnay/rust-toolchain@stable`).

### Claude Code on the web

`.claude/hooks/session-start.sh` provisions a Claude Code web session from the
same CI-derived values, in three tiers:

| Tier | What | When |
|------|------|------|
| Host | Flutter SDK, `flutter pub get`, host Rust library | always |
| Linux desktop | the apt packages from CI's `linux-desktop` job | wherever apt is usable |
| Android | SDK platform, build-tools, NDK, cross targets, emulator, `liberated_bread_test` AVD, `android/local.properties` | when `/dev/kvm` exists and there is disk for it |

The optional tiers skip themselves — with a logged reason — instead of failing
the session, and both can be forced or suppressed:

```bash
LB_SETUP_LINUX_DESKTOP=1|0   # default: auto (on wherever apt is usable)
LB_SETUP_ANDROID=1|0         # default: auto (on when KVM and disk allow)
```

The KVM condition matters: without `/dev/kvm` an x86-64 AVD falls back to
software emulation and is too slow to test with, so a container without it
skips a multi-gigabyte download that would not be usable anyway. Use the Linux
desktop target there instead (`./scripts/run-linux.sh --mock`), which is the
emulator-free path CI's `linux-desktop` job covers.

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

Install Android Studio or the command-line tools. Then — substituting the
versions `./scripts/ci-versions.sh` prints, since the NDK moves with the
Flutter pin:

```bash
sdkmanager "platform-tools" "build-tools;34.0.0" \
  "platforms;android-$(./scripts/ci-versions.sh | sed -n 's/^CI_ANDROID_API=//p')" \
  "ndk;$(./scripts/ci-versions.sh | sed -n 's/^CI_NDK_VERSION=//p')"
```

Set `ANDROID_HOME`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
```

For the emulator, add the emulator package and the system image CI boots, then
create the AVD `scripts/run-android.sh` looks for:

```bash
sdkmanager "emulator" "system-images;android-34;google_apis;x86_64"
avdmanager create avd -n liberated_bread_test \
  -k "system-images;android-34;google_apis;x86_64" -d pixel_6
```

Emulation needs KVM on Linux (`sudo apt-get install -y qemu-kvm && sudo usermod -aG kvm "$USER"`,
then log out and back in). Check with `ls -l /dev/kvm`; without it the x86-64
image runs under software emulation and is too slow to be useful.

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

### Build for Linux Desktop

```bash
flutter build linux --release --target-platform=linux-x64
flutter build linux --debug   --target-platform=linux-x64
```

Output lands in `build/linux/x64/{debug,release}/bundle/` — a relocatable
directory containing the `liberated_bread_mobile` executable, `data/` (Flutter
assets and ICU data) and `lib/` (the Flutter engine, the plugin `.so` files, and
`libliberated_bread_core.so`).

`--target-platform` defaults to `linux-x64`; pin it so an arm64 host fails
loudly rather than silently producing an untested artifact.

Verify the bundle actually contains the Rust library:

```bash
./scripts/verify_linux_bundle.sh build/linux/x64/release/bundle
```

This is not ceremony. `flutter build linux` exits 0 whether or not cargokit
bundled the Rust `.so`: `linux/flutter/generated_plugins.cmake` looks the
library up through `${liberated_bread_core_bundled_libraries}`, and CMake
expands an undefined variable to the empty string instead of erroring. When
`rust_builder/linux/CMakeLists.txt` exported the wrong variable name, the build
stayed green and the app died on the first FFI call with
`Failed to lookup symbol`. The script also checks the executable's
`RUNPATH` includes `$ORIGIN/lib` — without it the `.so` is present and still
unreachable at runtime.

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

# Linux desktop — no emulator, no simulator, hot reload
./scripts/run-linux.sh --mock
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
- `integration_test/ci_all_test.dart` — aggregate entrypoint importing the
  mock-safe suites above. On a device, every file passed to `flutter test` is
  its own build → install → launch cycle, so this is the file to run (and the
  one CI's device jobs run): one cycle instead of one per file. CI fails if a
  new mock-safe `*_test.dart` is missing from its imports.

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

### Integration tests on the Linux desktop (no emulator)

The flow tests run on the Linux desktop target, which is by far the quickest
way to execute them — and headlessly, so a machine with no display works:

```bash
xvfb-run -a flutter test integration_test/mock_flow_test.dart \
  -d linux --dart-define=LIBERATED_BREAD_MOCK=true
```

**Run one file per invocation.** Passing the whole `integration_test/`
directory at once works on Android and iOS but not on the Linux desktop: the
first file passes, then the tool reuses its VM-service connection for the next
and fails immediately with

```
Bad state: Cannot add new events after calling close
  dart:io-patch/socket_patch.dart 2455:41  _Socket._onData
```

That's flutter_tools closing the observatory socket when the first app exits
and still receiving data on it — a tooling bug, not an app bug. The same file
passes on its own in ~23 seconds. CI therefore loops over the files one at a
time; mirror that locally (skipping `ci_all_test.dart` — it exists for the
device jobs, and here it would only re-run the suites this loop already runs
individually):

```bash
for t in integration_test/*_test.dart; do
  [ "$(basename "$t")" = ci_all_test.dart ] && continue
  xvfb-run -a flutter test "$t" -d linux --exclude-tags=e2e \
    --dart-define=LIBERATED_BREAD_MOCK=true
done
```

Two more things worth knowing:

- **Build the app first**, or the first file may time out. `flutter test`
  builds during its *loading* phase, and `package:test_core` caps that at a
  hardcoded 12 minutes no flag can raise. A cold build blows it; running
  `flutter build linux --debug --dart-define=LIBERATED_BREAD_MOCK=true`
  beforehand drops the load to ~20 seconds. (`--concurrency` does not help —
  `flutter test` ignores it for integration tests.)
- `e2e_walkthrough_test.dart` has every test tagged `e2e`, so with
  `--exclude-tags=e2e` it prints `No tests ran.` and exits 1. That's a skip,
  not a failure — CI matches that message explicitly.

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

<a id="linux-desktop"></a>

- **Linux desktop app**: supported, and the fastest way to iterate. `linux/` is
  committed and `./scripts/run-linux.sh --mock` builds a native GTK app with
  hot reload — no emulator, no simulator, no device pairing. Install the
  [Linux desktop dependencies](#linux-desktop-builds) first. x86-64 is the
  supported target; `linux-arm64` builds exist in Flutter but are untested here.
- **BLE permissions**: Real BLE scanning may require root access or adding
  your user to the `bluetooth` group:
  ```bash
  sudo usermod -a -G bluetooth $USER
  # Log out and back in
  ```
- **BLE on the desktop goes through BlueZ**: `flutter_blue_plus` is federated,
  and `flutter_blue_plus_linux` talks to BlueZ over D-Bus. That is real
  Bluetooth, so it needs a physical adapter with `bluetoothd` running — a
  container or VM has neither, and scans there simply find nothing. Use
  `--mock` unless you have hardware. Note this implementation is pure Dart, so
  unlike the other plugins it ships no `.so` in the bundle.
- **`permission_handler` has no Linux implementation**, and the app doesn't need
  one: `lib/services/real_ble_service.dart` only calls it under
  `if (Platform.isAndroid)`, and every other platform falls through to
  "granted". BlueZ enforces access at the D-Bus level instead. Don't add
  permission_handler Linux code to "fix" this.
- **Window size**: `linux/my_application.cc` opens the window phone-shaped
  (430x900) rather than the template's 1280x720, because every screen in
  `lib/screens/` is laid out for a phone. Resize freely to check responsive
  behaviour.
- **Headless**: `./scripts/run-linux.sh --headless --mock` runs under Xvfb for
  machines with no display (`sudo apt-get install -y xvfb`). Expect benign
  `Gtk`/`Atk` CRITICAL warnings about GSettings and `atk_socket_embed` — a bare
  X server has no GNOME settings schema or AT-SPI bus, and the app runs anyway.
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
every pull request. Six jobs:

| Job | Runner | What it does |
|-----|--------|--------------|
| `flutter` | ubuntu-latest | `dart format --set-exit-if-changed`, `flutter analyze --fatal-infos`, builds the host Rust lib, checks the FRB bindings haven't drifted from `rust/src/api/`, `flutter test --coverage`, upload coverage to Codecov |
| `rust` | ubuntu-latest | `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --all-features` |
| `android-build` | ubuntu-latest | `flutter build apk --debug --dart-define=LIBERATED_BREAD_MOCK=true`; uploads the APK artifact |
| `android-integration` | ubuntu-latest (API 34 emulator) | warms the Gradle/cargokit caches with an `--target-platform android-x64` APK build (the emulator's ABI), frees runner disk, then `flutter test integration_test/ci_all_test.dart --timeout 1200s --dart-define=LIBERATED_BREAD_MOCK=true` on the emulator |
| `ios-build` | macos-latest | starts a simulator booting in the background, `flutter build ios --debug --no-codesign --simulator --dart-define=LIBERATED_BREAD_MOCK=true`, verifies the bundle, then runs `integration_test/ci_all_test.dart` on the (by now booted) simulator |
| `linux-desktop` | ubuntu-latest | installs the GTK toolchain, builds release + debug (`--target-platform=linux-x64`), runs `scripts/verify_linux_bundle.sh` against both bundles, then runs the integration tests headlessly under Xvfb in mock mode |

Caches: Flutter SDK, `~/.pub-cache`, `.dart_tool`, `rust/target/` and (in both
Android jobs) the Gradle user home are cached across runs. The quick checks run
first; the native build jobs wait for them to pass before spending runner time
on the slower platform builds (fail fast on lint/test).

There is a second workflow, `.github/workflows/ios-adhoc.yml`, triggered
manually to produce a signed ad-hoc IPA. It pins no toolchain versions of its
own: a step sources `scripts/ci-versions.sh` and feeds the Flutter version and
iOS Rust targets it reads out of `ci.yml` into the setup actions, so the
shipped IPA is always built with the SDK the rest of CI tested. Because that
read happens after checkout, building an old ref uses that ref's pins.

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
