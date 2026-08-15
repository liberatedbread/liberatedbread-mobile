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
| Flutter | 3.44+ (stable) | `flutter --version` |
| Rust | stable (1.85+) | `rustc --version` |

No `cargo-ndk` needed: cargokit (the flutter_rust_bridge native-build plugin)
drives the NDK itself during `flutter build`.

### Android Builds

| Tool | Version |
|------|---------|
| Android SDK | API 36 — the pinned Flutter's `flutter.compileSdkVersion` |
| Android NDK | CI's `FLUTTER_NDK_VERSION` — the pinned Flutter's `flutter.ndkVersion` |
| Android SDK Build-Tools | CI's `ANDROID_BUILD_TOOLS` — AGP 8.6's default; a newer one only adds a download |
| Java (for Gradle) | 17+ |

The emulator is a separate axis: it boots API 34 (see the CI table below), and
nothing requires it to match the compile SDK.

Every pinned version is declared once, in the top-level `env:` block of
`.github/workflows/ci.yml`, and each step interpolates it (`${{ env.KEY }}`, or
`$KEY` inside `run:`). `scripts/ci-versions.sh` reads exactly that block —
nothing else in the file — which is what lets the setup scripts provision the
same toolchain CI uses. **To pin something new, add a key there and reference
it; do not inline a version at a use site.** The parser previously scraped
values out of step bodies with file-wide greps, and a version named in a
*comment* could change what dev machines installed.

One value is repeated rather than interpolated: GitHub does not expose the
`env` context to `strategy:`, so the emulator job's `api-level` matrix carries
the literal alongside `ANDROID_EMULATOR_API`.
`test/platform/deployment_targets_test.dart` asserts the two agree.

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
eval "$(./scripts/ci-versions.sh)"
# xvfb is in the list: CI runs the app headlessly and so can you.
sudo apt-get update && sudo apt-get install -y --no-install-recommends \
  ${CI_LINUX_DESKTOP_PACKAGES}
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
7. Sets up Android SDK components (platform, build-tools, CMake, NDK)
8. Installs the emulator and system image and creates the
   `liberated_bread_test` AVD — same image and device profile CI boots
9. Runs `pod install` on macOS
10. Runs `flutter pub get` and generates FRB bindings

### Where the versions come from

None of the above are pinned in the setup script.
`scripts/ci-versions.sh` reads them out of `.github/workflows/ci.yml` — the
Flutter version, NDK, Android API, build-tools and CMake, the FRB codegen pin, the
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
| Android | SDK platform, build-tools, CMake, NDK, cross targets, emulator, `liberated_bread_test` AVD, `android/local.properties` | when `/dev/kvm` exists and there is disk for it |

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
flutter --version    # Should match ci.yml's FLUTTER_VERSION
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
eval "$(./scripts/ci-versions.sh)"
cargo install --locked "flutter_rust_bridge_codegen@${CI_FRB_VERSION}"
```

### 4. Android SDK

Install Android Studio or the command-line tools. Then — substituting the
versions `./scripts/ci-versions.sh` prints, since the NDK moves with the
Flutter pin:

```bash
# One eval, then interpolate — ci-versions.sh prints every CI_* value.
eval "$(./scripts/ci-versions.sh)"
sdkmanager "platform-tools" \
  "platforms;android-${CI_ANDROID_API}" \
  "build-tools;${CI_BUILD_TOOLS_VERSION}" \
  "cmake;${CI_CMAKE_VERSION}" \
  "ndk;${CI_NDK_VERSION}"
```

Set `ANDROID_HOME`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
```

For the emulator, add the emulator package and the system image CI boots, then
create the AVD `scripts/run-android.sh` looks for:

```bash
eval "$(./scripts/ci-versions.sh)"
sdkmanager "emulator" "${CI_EMULATOR_SYSTEM_IMAGE}"
avdmanager create avd -n liberated_bread_test \
  -k "${CI_EMULATOR_SYSTEM_IMAGE}" -d "${CI_EMULATOR_PROFILE}"
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
- Auto-upgrades the repo-managed SDK at `~/.flutter-sdk` to CI's pinned
  `FLUTTER_VERSION` when it is stale, so a version bump in `ci.yml` doesn't fail
  later inside `flutter pub get`. A Flutter installed elsewhere is left alone;
  set `LB_FLUTTER_AUTO_UPGRADE=0` to skip the check.
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
- `integration_test/app_launch_test.dart` — boots the app through its **real**
  entrypoint (`lib/main.dart`'s `main()`) and waits for the scan screen. Every
  other test constructs `LiberatedBreadApp` itself with overridden providers,
  which meant `main()` was executed by nothing and did not appear in
  `coverage/lcov.info` at all. It owns the ordering and wiring the shipped app
  depends on: `RustLib.init()`, resolving `SharedPreferences` *before* `runApp`,
  and the one un-overridden `ProviderScope`. A break in any of those is an app
  that dies on launch while the whole suite stays green.
- `integration_test/error_flow_test.dart` — error state + retry
- `integration_test/native_core_test.dart` — loads the **bundled** Rust core on
  the device and calls through it. The three bundle verifiers
  (`verify_apk.sh`, `verify_ios_app.sh`, `verify_linux_bundle.sh`) assert the
  native artifact is *present and exports the right symbols*, which is a static
  check on a file; nothing ever `dlopen`ed it on a device. `lib/main.dart`
  catches a failed `RustLib.init()` and carries on against the Dart mock by
  design, so a framework with a wrong install name, an `.so` for the wrong ABI,
  or bindings that no longer match the crate would all have shipped green. Here
  they are a hard failure. Runs last in the aggregate: `RustLib` is
  process-wide, and initializing it earlier changes what the suites above test.
- `integration_test/e2e_walkthrough_test.dart` — scripted screenshot
  walkthrough, tagged `e2e` (see below)
- `integration_test/ci_all_test.dart` — aggregate entrypoint importing the
  mock-safe suites above. **Group order is load-bearing and deliberately not
  alphabetical**: `app_launch` and `native_core` bring up `RustLib`, which is
  process-wide, and the aggregate is one process — so they run last. Put
  `app_launch_test.dart` in its alphabetical position (first) and
  `mock_flow_test.dart` fails on the device jobs with `Found 0 widgets with
  text "Battery Service"`, because the real codec parses the bulb spec and the
  screen renders spec-driven controls instead of the raw GATT list. The
  `linux-desktop` job cannot catch it (one process per file), so
  `test/platform/integration_aggregate_test.dart` pins the ordering. On a device, every file passed to `flutter test` is
  its own build → install → launch cycle, so this is the file to run (and the
  one CI's device jobs run): one cycle instead of one per file. CI fails if a
  new mock-safe `*_test.dart` is missing from its imports.

### FRB-backed tests

`test/services/mock_ble_service_rust_test.dart` exercises the Rust mock API
through flutter_rust_bridge. Unlike a normal `flutter test`, the host-target
Rust library has to exist at runtime — `flutter test` runs on your machine, not
a device, so it dynamically loads the desktop build of the Rust core.

You do not have to remember to build it:

```bash
flutter test test/services/mock_ble_service_rust_test.dart
```

`test/helpers/host_rust_lib.dart` reads cargo's dep-info file
(`rust/target/debug/libliberated_bread_core.d`) — the list of every source that
went into the artifact, `include_str!`d vendor files included — and runs
`cargo build` when any of them is newer than the library, or when there is no
library at all. A warm, up-to-date target directory means no cargo run at all;
a cold one costs the build once per test process.

**Why the helper does this rather than leaving it to you.** Both failure modes
here are silent. With no build, the suites `markTestSkipped` and the run is
green with a quietly smaller test count. With a *stale* build they do not even
skip: they load the `.so` from before your edit, pass, and report on code that
no longer exists. `scripts/test.sh` and CI always build first, but they are not
where a change gets iterated on.

Opt out with `LIBERATED_BREAD_NO_RUST_BUILD=1`, or point
`LIBERATED_BREAD_RUST_LIB` at an artifact you built yourself (which is treated
as "the caller owns this file" and never rebuilt). To build it explicitly:

```bash
./scripts/ensure-rust-lib.sh              # debug, and asserts the cdylib landed
./scripts/ensure-rust-lib.sh --release
./scripts/ensure-rust-lib.sh --print-path
```

That script is what `scripts/test.sh`, the Claude Code session hook and CI's
`unit-tests` job all run, and it checks the artifact rather than trusting
cargo's exit code: dropping `cdylib` from `rust/Cargo.toml`'s `crate-type`, or
renaming the package, still builds green while removing the one file every
FFI-backed test opens by path.

No `LD_LIBRARY_PATH` is involved. On macOS `DYLD_FALLBACK_LIBRARY_PATH` does
**not** work at all: the Flutter SDK's `dart` binary uses the hardened runtime,
and the loader strips `DYLD_*` from such processes. The helper opens
`rust/target/debug/<lib>` (then `release/`) by relative path instead.

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
`dart_test.yaml`. Every CI job passes `--exclude-tags=e2e`, but on the device
jobs that flag only filters group/test-level tags — a *file*-level `@Tags` is
read from the entrypoint only, so what actually keeps this suite off a device
is that `integration_test/ci_all_test.dart` does not import it
(`test/platform/integration_aggregate_test.dart` asserts both directions).

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
time, and that loop is a script you can run yourself — it skips
`ci_all_test.dart` (the device jobs' aggregate, which here would only re-run
the suites the loop already runs individually) and any `e2e`-tagged file, and
it collects failures so one run reports every broken suite:

```bash
./scripts/ci-linux-tests.sh
# or one file, to iterate:
LB_LINUX_TEST_FILES=integration_test/mock_flow_test.dart ./scripts/ci-linux-tests.sh
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
- `vendored_assets.rs` — asserts every bundled spec in
  `vendor/protocol-specs/device-specs/`
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
- **App icon, and finding the window in alt-tab**: `linux/my_application.cc`
  loads the PNGs the build copies to `data/resources/` and sets them as the
  default window icon list, so the app shows the mascot rather than a generic
  placeholder. That covers X11 and XWayland, which read the icon off the window
  itself.

  A **native Wayland session ignores window icons entirely** — the protocol has
  none. The compositor matches the surface's `app_id` (which `linux/main.cc`
  sets to `ca.pigscanfly.liberatedbread`) to an installed `.desktop` file and
  uses the icon named there, so an app run straight out of `build/` has nothing
  to match and stays anonymous in the switcher. Install the missing half once:

  ```bash
  ./scripts/install-linux-desktop-entry.sh          # newest built bundle
  ./scripts/install-linux-desktop-entry.sh --uninstall
  ```

  It writes only under `~/.local/share` (no root), and points at the bundle in
  place — so rebuilding in the same mode keeps working, while `flutter clean` or
  switching debug/release means re-running it. Nothing in the build does this
  for you on purpose: a build should not write into your desktop environment
  behind your back.
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
every pull request. Seven jobs:

| Job | Runner | What it does |
|-----|--------|--------------|
| `analyze` | ubuntu-latest | `scripts/ci-format.sh`, `flutter analyze --fatal-infos`, `scripts/ci-shellcheck.sh`, `scripts/ci-ios-tests-selftest.sh`. Dart only — no Rust toolchain, nothing compiled |
| `unit-tests` | ubuntu-latest | builds the host Rust lib, checks the FRB bindings haven't drifted from `rust/src/api/`, `flutter test --coverage`, upload coverage to Codecov |
| `rust` | ubuntu-latest | `cargo fmt --all -- --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --all-features` |
| `android-build` | ubuntu-latest | debug **and** release APK, each checked with `scripts/verify_apk.sh`; uploads the debug APK artifact |
| `android-integration` | ubuntu-latest (API 34 `aosp_atd` emulator) | warms the Gradle/cargokit caches with an `--target-platform android-x64` APK build (the emulator's ABI), frees runner disk, then runs `integration_test/ci_all_test.dart` on the emulator via `scripts/ci-emulator-tests.sh` — twice if the first attempt hits its per-attempt timeout (see below) |
| `ios-build` | macos-latest | starts a simulator booting in the background, builds the **test entrypoint** for the simulator (`--target=integration_test/ci_all_test.dart`) so the build inside `flutter test`'s 12-minute loading window is incremental rather than a near-repeat, verifies the pods and the bundle, then runs that entrypoint on the simulator via `scripts/ci-ios-tests.sh` |
| `linux-desktop` | ubuntu-latest | installs the GTK toolchain, builds release + debug (`--target-platform=linux-x64`), runs `scripts/verify_linux_bundle.sh` against both bundles, then runs `scripts/ci-linux-tests.sh` headlessly under Xvfb in mock mode |

`analyze` and `rust` are the gate: the four native jobs wait on those two, so a
change that does not compile or does not lint never reaches a platform build.

`unit-tests` deliberately is **not** part of that gate. It used to be — it was
the second half of a single `flutter` job — and every native job sat behind its
test run, its host Rust build and its codegen check for no benefit.

The split is drawn at *what the native builds actually need before it is worth
starting them*, which is why `analyze` compiles nothing at all: `dart format`
and `flutter analyze` are static, and the generated bindings they read are
committed. The FRB drift check in particular is in `unit-tests` and not in the
gate, and that placement was earned the hard way — left in the gate it
dominated it (~90s to `cargo install` the codegen plus ~80s of `generate`
against a cold `rust/target`), measuring 242s and 257s on two runs, *slower
than the single job the split replaced*. Caching helps and is still done, but a
gate whose speed depends on a warm cache is slow exactly when a contributor is
least able to explain why. Off the critical path it can take as long as it
likes, and it still runs on every pull request.

The remaining cost is real and worth knowing: a pull request whose *only*
failure is a unit test now also spends the macOS job's (10x-billed) minutes
before that shows up. Adding `unit-tests` back to the native jobs' `needs:`
reverses the trade.

Every long step carries its own `timeout-minutes` as well as the job's, so a
hung build fails in minutes rather than burning the whole job budget — which
matters most on `ios-build`, where the budget is billed at 10x.

### What CI caches

| Cache | Where it comes from | Covers |
|-------|--------------------|--------|
| Flutter SDK + `~/.pub-cache` | `subosito/flutter-action` (`cache: true`) | every job |
| `.dart_tool` | an explicit `actions/cache` step | the `analyze` and `unit-tests` jobs |
| `~/.cargo/bin/flutter_rust_bridge_codegen` | an `actions/cache` keyed on `FRB_VERSION` | the `unit-tests` job — one file, one key, so a cancelled run cannot leave a half-saved snapshot the way `rust-cache`'s `cache-bin` did |
| `rust/target/` + `~/.cargo` | `Swatinem/rust-cache` | every job that compiles Rust |
| Gradle user home | `gradle/actions/setup-gradle` | both Android jobs |

`setup-gradle` is read-only on non-default branches, so a PR reads the cache
that a `main` run wrote — the first run after a change to the Android build
does not benefit, later ones do.

**The one thing not cached, and why it stays that way.** cargokit does not
build into `rust/target`, so `Swatinem/rust-cache` never sees its output. It
passes `--target-dir` explicitly: on Android that is the Gradle build directory
(`plugin.gradle`), and on iOS it is Xcode's `TARGET_TEMP_DIR`
(`cargokit/build_pod.sh`). Every job therefore recompiles the Rust crate for
its cross-target from scratch.

That sounds worth fixing and is not. Measured directly — a from-scratch build
of the whole 87-crate dependency graph into an empty target dir:

| | |
|---|---|
| compile time saved | **13.6s** |
| cache that would buy it | **366 MB** |

Restoring 366 MB costs several seconds before decompression even at a generous
100 MB/s, has to be re-uploaded whenever the lockfile moves, and competes with
the 2 GB Flutter SDK cache every job depends on inside the repo's 10 GB budget.
The dependencies are light (serde, indexmap, serde_yaml, thiserror, anyhow,
flutter_rust_bridge), which is why the number is so small. It is a losing trade
on Android and still a losing one on the 10x-billed macOS runner, where 13.6s
is worth about two billed minutes and the cache round-trip would eat most of
it. Revisit only if the dependency graph grows heavy enough to move that 13.6s
substantially.

The other iOS candidates were checked and rejected for the same
measure-first reason: `pod install` runs in **1.6s** (the plugin pods are local
path pods, so there is nothing to download), and caching Xcode's DerivedData
is defeated before it starts — a fresh `git checkout` gives every source a new
mtime, and `pod install` regenerates `ios/Pods/`, so Xcode treats both as dirty
and recompiles regardless of what was restored. Cargo is the exception that
makes `rust-cache` work at all: it fingerprints against a restored
`~/.cargo/registry`, whose mtimes are stable.

### The Android emulator flake, and what is done about it

`android-integration` has hung for its whole step timeout with **zero Dart
output**, while the same suites passed on Linux/Xvfb and the iOS simulator
(run 31142032906 on `main`). That looks like a graphics failure and is not one.
Diffing that run's logcat against a passing run's:

- `FlutterRenderer: Width is zero. 0,0` appears in **both**. It is normal
  startup noise, not the fault.
- Only the failing run logs `onDetachedFromActivityForConfigChanges`. Four
  seconds after the Dart VM service came up, a configuration change destroyed
  and recreated `MainActivity` with a fresh `FlutterEngine`. `flutter_tools`
  had already attached to the first engine's isolate, so it waited forever on
  an isolate that would never run a test — the app process sat idle for 55
  minutes. Zero Dart output is exactly what an orphaned VM-service attach looks
  like.
- In the 90 seconds before launch: an ANR in `nexuslauncher`, an ANR in
  `gms.persistent`, long monitor contention in `system_server`, Play Services
  reaping processes "to refresh configuration". The system was still settling
  when the app launched into it.

`android/app/src/main/AndroidManifest.xml` already declares the same
`configChanges` set Flutter's own template does, so there is no missing flag to
add. Two changes address it instead:

1. **`aosp_atd`** rather than `google_apis` — Google's Automated Test Device
   image, without the launcher and Play Services stack that was doing the
   churning. It also boots faster.
2. **Two attempts, each bounded by `ANDROID_EMULATOR_ATTEMPT_TIMEOUT`.** The
   bound is the load-bearing part: this failure *hangs* rather than exiting
   non-zero, so with only the step's `timeout-minutes` to stop it there is
   nothing left to retry with. By the time attempt 1 has burned its budget the
   emulator has settled, so attempt 2 starts from the state attempt 1 wanted.
   A retry that passes still prints a `::warning::` and keeps both logcats — a
   flake that leaves no trace is a flake nobody fixes.

That retry lives in **`scripts/ci-emulator-tests.sh`**, not in the workflow.
`reactivecircus/android-emulator-runner` does not run its `script:` input as a
script: it splits the input on newlines and execs each line separately as
`/usr/bin/sh -c '<line>'`. So a function body or an `if`/`fi` never parses
(the shell hits end-of-input mid-construct), a `set -u` on one line does not
apply to the next, and `/usr/bin/sh` is dash on the Ubuntu runner — no
`pipefail`. The workflow therefore passes one line, `./scripts/ci-emulator-tests.sh`,
and the logic lives in a bash file that can be run against stub `flutter`/`adb`
binaries on a laptop instead of only in a 40-minute CI job. Set
`LB_EMULATOR_ATTEMPTS=1` to reproduce a failure without waiting out the retry.

### The iOS simulator job, and why it has the same shape

`ios-build` had neither of the two things the emulator job needed, on the most
expensive runner in the matrix. The iOS failures that matter — dyld unable to
resolve the embedded `liberated_bread_core.framework`, a wedged CoreSimulator,
an install that never returns — *hang* exactly the way the Android settling
race did: `flutter test` waits on a VM service that never appears and prints
nothing at all until the job's 60-minute budget runs out, at 10x.

So **`scripts/ci-ios-tests.sh`** now owns the simulator lifecycle:

* **Per-attempt bound plus one retry**, on an *erased* device. The bound is
  again the load-bearing part — a hang leaves no failure to retry. macOS ships
  no `timeout`, so the script uses one when the runner image has it and falls
  back to a `sleep`-based watchdog that returns the same exit code (124) when
  it does not. That is why `IOS_SIMULATOR_ATTEMPT_TIMEOUT` is whole seconds
  with no unit suffix: BSD `sleep` takes no suffix, and the two paths have to
  agree or the bound silently disappears on one of them.
* **The simulator's own log and any crash report**, uploaded as the
  `ios-simulator-diagnostics` artifact on every run, pass or fail. When the
  step log is empty this is the only evidence there is. It is predicate
  filtered to `Runner`, `SpringBoard`, `launchd_sim` and `CoreSimulatorBridge`
  — an unfiltered stream is tens of MB a minute and buries the four processes
  that can explain a launch failure.

On a Mac the whole thing runs as one command:

```bash
./scripts/ci-ios-tests.sh          # pick a simulator, boot it, run the suite
LB_IOS_ATTEMPTS=1 ./scripts/ci-ios-tests.sh   # reproduce a failure, no retry
```

And the retry loop itself is tested **without** a Mac, which matters more than
it sounds: a simulator that will not boot cannot be produced on demand even on
real hardware, so left alone that logic would only ever be exercised by the
failure it exists to survive — at 10x, once, mid-incident.
`scripts/ci-ios-tests-selftest.sh` drives it through all seven outcomes against
stub `xcrun`/`flutter` binaries in about twenty seconds, and runs in the
`analyze` job and in `scripts/test.sh`:

```bash
./scripts/ci-ios-tests-selftest.sh
```

That harness exists because the first version of the script waited for the
initial boot *outside* the retry loop, with an unbounded `simctl bootstatus -b`
— so the one failure the retry most wanted to survive would have hung until the
step timeout killed everything, with no erase, no retry and no log. A reviewer
caught that by reading it. The self-test is there to catch the next one by
running it.

### Why `dart format .` is not what CI runs

`scripts/ci-format.sh` formats the tracked Dart files (`git ls-files '*.dart'`)
rather than the working tree. `dart format .` walks `build/`, where cargokit
stages its own `build_tool_runner.dart` — so it reformats somebody else's
vendored source and then fails because it changed something. CI never hit it,
because the format check runs before anything is built; **`./scripts/test.sh`
hit it on every machine where the app had ever been run**, which is the
green-in-CI-red-locally inversion that script exists to prevent, inverted.

Deriving the list from git rather than naming `lib/ test/ …` matters for the
opposite failure: a new top-level Dart file or directory would silently stop
being formatted, and nothing would say so. Build output is gitignored, so it
drops out for free.

```bash
./scripts/ci-format.sh          # check
./scripts/ci-format.sh --write  # reformat in place
```

### Shell is linted too

The CI logic in this repo deliberately lives in `scripts/` rather than in
`run:` blocks, so it can be run on a laptop. That moves a growing pile of shell
out from under every other check in the project — Dart has
`flutter analyze --fatal-infos`, Rust has `clippy -D warnings`, the shell had
nothing. `scripts/ci-shellcheck.sh` closes that, in the `analyze` job and in
`scripts/test.sh`. Its first run found `scripts/run-ios.sh` piping simctl's
JSON into `python3 - <<'PY'`, where the heredoc overrides the pipe — so
`pick_simulator` had never once worked.

It also checks two things shellcheck has no opinion about: that every script is
**executable** and that it declares an **interpreter**. Both are invisible in a
diff and expensive to learn about anywhere else — git tracks the mode bit, and
a script committed 644 fails with `Permission denied` at the moment CI invokes
it, which for `scripts/ci-emulator-tests.sh` is forty minutes into the emulator
job. A missing `#!` is quieter still: executed directly, the file is handed to
the caller's shell, which on the Ubuntu runners is dash — no `pipefail`, no
`[[ ]]`.

There is a second workflow, `.github/workflows/ios-adhoc.yml`, triggered
manually to produce a signed ad-hoc IPA. It pins no toolchain versions of its
own: a step sources `scripts/ci-versions.sh` and feeds the Flutter version and
iOS Rust targets it reads out of `ci.yml` into the setup actions, so the
shipped IPA is always built with the SDK the rest of CI tested. Because that
read happens after checkout, building an old ref uses that ref's pins.

### The pins and the lockfiles are checked, not just written down

Three checks exist because the thing they guard fails *silently* — the run stays
green and the damage shows up somewhere else, later.

**`./scripts/ci-versions.sh --strict`**, in the `analyze` job. `ci.yml`'s
top-level `env:` block is the toolchain source of truth for dev environments:
`scripts/setup.sh` and `.claude/hooks/session-start.sh` provision from whatever
that script reads out of it. The script is deliberately forgiving — a key it
cannot find degrades to a hardcoded fallback and a line on stderr — which meant
renaming a key had *no observable effect at all*. CI kept interpolating its own
`env:` values and passed; every laptop and every Claude Code session started
quietly provisioning from a default drifting further behind with each bump, and
the symptom arrived months later as "works in CI, not on my machine".
`--strict` turns each of those stderr lines into a failed gate, in the pull
request that renames the key.

**`cargo --locked`**, on the `rust` job's clippy and test steps. Without it
cargo silently *rewrites* `rust/Cargo.lock` in the runner's checkout when it
disagrees with `Cargo.toml`, so a dependency bump that forgets the lockfile
passes CI against a resolution that exists on that one runner and nowhere else.

**`flutter pub get --enforce-lockfile`**, in the `analyze` job only — the same
hole on the Dart side. One job asking is enough; the others need the packages,
not a second copy of the assertion, and a native build re-runs pub itself.

`.github/dependabot.yml` covers the remaining moving part: the ten third-party
actions the workflows pin by major tag. A major tag is a moving target right up
until it stops moving (`actions/upload-artifact@v3` was switched off outright),
and nothing else in this repo watches for that. Grouped into one pull request
per ecosystem per week. Pub is deliberately excluded — `pubspec.lock` is pinned
against a specific Flutter SDK, so bumps follow a Flutter bump, by hand.

### Running CI locally

`scripts/test.sh` mirrors the `analyze`, `unit-tests` and `rust` jobs,
including the FRB binding drift check, the shellcheck pass and the
`ci-versions.sh --strict` pin check (the first two skipped with a warning when
the tool they need isn't installed):

```bash
./scripts/test.sh
```

Exits non-zero on the first failure.

### Codecov

Coverage uploads use `codecov/codecov-action@v5`. Set a `CODECOV_TOKEN` repo
secret if your fork is private; public repos don't need one.

`codecov.yml` makes the policy explicit, where before it was whatever Codecov's
defaults happened to be:

- **`lib/src/rust/**` is ignored.** It is flutter_rust_bridge output — 1037 of
  4426 measured lines, 23% of the codebase, sitting at 40% and dragging the
  reported total to 75.2% while hand-written code was at 86%. Nobody writes or
  reviews those lines. They are *not* unverified: the `unit-tests` job
  regenerates them and fails on any diff, and
  `integration_test/native_core_test.dart` executes them through the real crate
  on an iOS simulator, an Android emulator and the Linux desktop — more than a
  host-only line count was doing for them. The effect is that the number now
  tracks code a change can be careless with.
- **`project` status**: `auto` against the base commit, 1% threshold. Blocks a
  cliff, tolerates the few tenths that unrelated changes move.
- **`patch` status**: `informational: true` — it reports how well a diff's new
  lines are covered and never fails. Making new code blocking is a policy call;
  flip `informational` to `false` to enforce it.

#### Three uploads, one report

Codecov merges every report for a commit, so each job sends a partial one under
its own flag:

| flag | job | what only it covers |
| --- | --- | --- |
| `unit` | `unit-tests` | `flutter test --coverage --exclude-tags=netdisco` |
| `netdisco` | `network-discovery` | the suites that run excludes — the only place `RealNetworkScanService` executes |
| `rust` | `rust-coverage` | the crate, via `cargo llvm-cov` |

Both of the latter two exist because their code was being tested and then not
counted. `real_network_scan_service.dart` measured 108/169 lines in the uploaded
report while the netdisco job was covering 164/169 of it. And the whole of
`rust/` — roughly a third of the hand-written code in the project — was measured
by nothing at all, so the reported figure was the Dart half only and a change
that moved Rust coverage moved the number not at all.

`carryforward` is deliberately unset. All three jobs run on every commit, so a
missing flag means an upload failed, and the number *should* move rather than
quietly reusing the last one.

#### Files no test imports are absent, not zero

```bash
./scripts/ci-coverage-audit.sh coverage/lcov.info    # runs in unit-tests and test.sh
```

`flutter test --coverage` instruments the libraries a test actually **imports**.
A file nothing reaches does not appear in `lcov.info` at all — it is not
reported as 0%, it is missing, which means it is missing from the denominator
too. The consequence is the wrong way round from what anyone expects: adding an
entirely untested file to `lib/` does not lower coverage, it moves it by
nothing, and the `project` status cannot see it.

`lib/main.dart` was living in that gap — the app's own entrypoint, executed by
nothing, invisible to every report. It is covered now (`test/main_test.dart`)
and this check is what stops the next one taking its place: it compares
`git ls-files lib/**.dart` against the `SF:` records and fails on anything
missing. Two files are allowlisted in the script, each with its reason, because
they are abstract declarations with nothing to instrument — and the allowlist is
checked in the other direction too, so an entry that starts appearing in a report
is an error rather than a silent exemption.

What it cannot see is stated in the script's header: a file that is on the
allowlist, grows executable code, and is *still* imported by no test stays
exempt. Keep the list short.

#### Rust coverage

```bash
./scripts/ci-rust-coverage.sh          # coverage/rust-lcov.info
```

It installs the pinned `cargo-llvm-cov` (`scripts/ci-install-llvm-cov.sh`, the
sibling of `ci-install-frb.sh` and cached the same way), runs the suite under
instrumentation, and rewrites the absolute paths llvm-cov emits into
repo-relative ones — Codecov's path fixing usually maps them itself, and
"usually" applied to a heuristic means the day it does not, the report silently
covers nothing and the number just drops. It refuses to pass having produced an
empty report, for the same reason.

`rust/src/frb_generated.rs` is ignored in `codecov.yml`, and it is the same
argument as `lib/src/rust/**` above: 1917 generated lines that `cargo test`
covers 0.0% of, because the crate's own tests never cross the FFI boundary that
file exists to implement — the Dart side does. Left in, it takes a crate whose
hand-written code measures **95.6%** to a reported **72.0%**.

The `rust-coverage` job is separate from the `rust` job and gates nothing. That
job is what android-build, android-integration, ios-build and linux-desktop wait
on, and putting a `cargo install` plus a second instrumented build in front of
all four — two multi-GB native builds and one billing at 10x — to measure
something is the wrong trade. It would not share a single object file either:
llvm-cov compiles with instrumentation into its own target directory. The
duplicated test run costs about twenty seconds on a cheap runner, in parallel.

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
