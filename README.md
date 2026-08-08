# Liberated Bread Mobile

[![CI](https://github.com/liberatedbread/liberatedbread-mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/liberatedbread/liberatedbread-mobile/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/liberatedbread/liberatedbread-mobile/branch/main/graph/badge.svg)](https://codecov.io/gh/liberatedbread/liberatedbread-mobile)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

> Because your phone should be able to talk to your smart lightbulb even after
> the manufacturer's servers have gone the way of the dodo.

A cross-platform **Flutter + Rust** app for communicating with Bluetooth Low
Energy (BLE) IoT devices via
[OpenGreenIoT](https://github.com/PigsCanFlyLabs/opengreeniot) by
[Pigs Can Fly Labs LLC](https://pigscanfly.ca).

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│                  Flutter (Dart)                   │
│  ┌────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │Screens │──│Providers │──│  BLE Service      │  │
│  │& Widgets│ │(Riverpod)│  │  (Real / Mock)    │  │
│  └────────┘  └──────────┘  └──────────────────┘  │
│                     │                             │
│         ┌───────────▼───────────┐                 │
│         │ flutter_rust_bridge   │                 │
│         │       (FFI)           │                 │
│         └───────────┬───────────┘                 │
├─────────────────────┼────────────────────────────┤
│                Rust Core                          │
│  ┌──────┐  ┌───────┐  ┌─────────┐  ┌──────────┐ │
│  │ Spec │──│ Codec │──│Protocol │──│ Profiles │ │
│  │(YAML)│  │(bytes)│  │(generic)│  │(BT SIG)  │ │
│  └──────┘  └───────┘  └─────────┘  └──────────┘ │
│  ┌──────┐  ┌────────────────────┐                │
│  │ Mock │  │  FFI API (DTOs)    │                │
│  └──────┘  └────────────────────┘                │
└──────────────────────────────────────────────────┘
```

**Flutter** handles the UI, BLE transport, and permissions.
**Rust** handles protocol logic: parsing YAML device specs, encoding commands,
decoding characteristic values, and implementing standard Bluetooth profiles.

## Features

- Scan for nearby BLE devices
- Connect and browse GATT services/characteristics
- Read/write characteristic values with hex display
- Standard BLE profile support (Battery Service, Device Information)
- YAML-driven device specs for custom IoT protocols
- Spec-driven typed device controls (buttons, sliders, decoded values —
  generated straight from the YAML)
- Downloadable remote spec packs — new device support without an app update
- Home Assistant companion mode (forward BLE sensor readings to HA)
- Secure on-device credential storage (HA tokens live in the platform
  keychain/keystore, never in plain preferences)
- Mock mode for development without BLE hardware
- Material Design 3 with light/dark themes

## Home Assistant Companion Mode

The app can register itself with a Home Assistant server (via HA's native
`mobile_app` integration - the same API the official companion apps use) and
forward live, spec-decoded sensor readings from your BLE devices - battery
level, power state, brightness, and so on - as Home Assistant sensor
entities.

Setup: tap the gear icon on the scan screen, enter your Home Assistant URL
and a long-lived access token (in HA: your profile → Security → Long-lived
access tokens), and hit Connect. Forwarding happens while the app is open
and connected to a device; nothing ever leaves your phone unless you enable
it, and you can disconnect at any time.

**Remote access tip:** most Home Assistant servers are only reachable at
home (`http://192.168.x.x:8123` or `homeassistant.local`). Instead of port
forwarding, we recommend [Tailscale](https://tailscale.com/kb/1123/home-assistant) -
free for personal use, it gives your HA server a magic `https://…ts.net`
address that works from anywhere. The setup screen recognizes LAN-only
addresses and points you there.

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Flutter | 3.44+ | Stable channel |
| Rust | stable (1.82+) | Via rustup |
| Android SDK | API 36 | The pinned Flutter's `flutter.compileSdkVersion`; NDK matches its `flutter.ndkVersion` |
| Xcode | 15+ | macOS only, for iOS builds |
| CocoaPods | latest | macOS only |
| GTK 3 + CMake/Ninja/clang | — | Linux desktop builds only — see below |
| Android emulator | API 34 `google_apis` x86-64 | Needs KVM on Linux; `./scripts/setup.sh` creates the AVD |

What the built app runs on, as opposed to what builds it: Android 7.0
(API 24), iOS 13, macOS 10.15. Those are the floors the pinned Flutter
supports, and `test/platform/deployment_targets_test.dart` fails if the files
declaring them ever disagree.

The exact versions live in `.github/workflows/ci.yml` and are read from there by
`scripts/ci-versions.sh` — the table is a summary, that command is the answer.

For the **Linux desktop** target (`./scripts/run-linux.sh`), `./scripts/setup.sh`
installs the native toolchain for you on apt-based distros; to do it by hand:

```bash
sudo apt-get update && sudo apt-get install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libsecret-1-dev libjsoncpp-dev
# optional: run headlessly (no display), as CI does
sudo apt-get install -y xvfb
```

`libsecret-1-dev` is for `flutter_secure_storage_linux` (Home Assistant token
storage); the rest is Flutter's standard Linux desktop toolchain.

## Quick Setup

The setup script installs everything: Flutter, Rust, FRB codegen, the Linux
desktop toolchain, and the Android SDK/NDK plus an emulator AVD
(`liberated_bread_test`) matching the one CI boots.

```bash
./scripts/setup.sh
```

This works on **Linux** and **macOS** (both Intel and Apple Silicon). See
[docs/BUILD_AND_TEST.md](docs/BUILD_AND_TEST.md) for manual setup and
platform-specific details.

Versions aren't pinned in the setup script: `scripts/ci-versions.sh` reads them
out of `.github/workflows/ci.yml`, so a local environment follows CI. Print
what yours will use with:

```bash
./scripts/ci-versions.sh
```

Claude Code web sessions provision themselves the same way through
`.claude/hooks/session-start.sh` (Flutter + Rust always; Linux desktop deps and
the Android SDK/emulator when the machine can use them — see
[Claude Code on the web](docs/BUILD_AND_TEST.md#claude-code-on-the-web)).

After setup, add Flutter to your PATH:

```bash
export PATH="$HOME/.flutter-sdk/bin:$PATH"
```

> **Android only:** if `flutter build apk` fails with a Java version mismatch,
> pin Gradle to JDK 17 in your *user-global* config — **never** in the committed
> `android/gradle.properties` (it breaks CI):
>
> ```bash
> mkdir -p ~/.gradle
> echo 'org.gradle.java.home=/usr/lib/jvm/java-17-openjdk-amd64' >> ~/.gradle/gradle.properties
> ```
>
> Or use Flutter's built-in: `flutter config --jdk-dir /path/to/jdk-17`.

### About platform scaffolds

`android/`, `ios/` and `linux/` are committed. To regenerate them (for example when
upgrading Flutter), back up the customized `android/app/src/main/AndroidManifest.xml`
and `ios/Runner/Info.plist` first — they contain BLE permissions and usage
strings — then run `flutter create . --platforms=android,ios,linux --project-name liberated_bread_mobile --org ca.pigscanfly`
and merge the customizations back in. Note the real identifiers don't follow
`flutter create`'s `<org>.<project>` convention: the app id is the flat
`ca.pigscanfly.liberatedbread` (see `android/app/build.gradle`, the Xcode
projects, and `APPLICATION_ID` in `linux/CMakeLists.txt`), so restore those
along with the manifest/plist customizations. For `linux/` also restore the
window title and default size in `linux/my_application.cc` — the template
resets them to the package name and 1280x720.

> **Watch what `flutter create` touches.** Run it on a dirty tree and diff the
> result before accepting it. On this project it also rewrites `.metadata`,
> **replacing** the existing platform entries rather than adding to them (a
> `--platforms=linux` run drops the `android`, `ios` and `macos` migration
> records), and it drops a stock `test/widget_test.dart` that references a
> `MyApp` widget this app doesn't have, which breaks `flutter test`.

## Running the App

```bash
# Connected device or emulator (auto-detect)
./scripts/run.sh

# Linux desktop — the fastest loop: no emulator, no simulator, hot reload
./scripts/run-linux.sh --mock

# Build + boot the Android emulator + install + run (Linux or macOS)
./scripts/run-android.sh --mock

# Build + boot the iOS Simulator + install + run (macOS only)
./scripts/run-ios.sh --mock

# Build + run on a paired physical iPhone (macOS only; --list shows devices,
# --device picks one — see docs/ios-from-linux.md)
./scripts/run-ios-device.sh --mock

# From Linux: build + run on an iPhone via a remote Mac over SSH,
# with automatic sync + hot reload on every save (see docs/ios-from-linux.md)
./scripts/run-remote-mac.sh --host user@mac.local --mock

# Mock mode (no BLE hardware needed) on whatever device run.sh picks
./scripts/run.sh --mock

# Manual (equivalent to run.sh --mock)
flutter run --dart-define=LIBERATED_BREAD_MOCK=true
```

The platform-specific scripts (`run-android.sh`, `run-ios.sh`) will boot an
emulator/simulator if one isn't already running. They accept `--mock`,
`--release`, and pass extra args after `--` to `flutter run`.
`run-ios.sh` also takes `--device "iPhone 15"` to pick a specific simulator.

### Linux desktop

`./scripts/run-linux.sh` builds a native GTK app and runs it on your desktop
(x86-64). It's the quickest way to iterate on the UI — no emulator to boot, no
device to pair, and hot reload works on the same Dart code that ships on mobile.
It also takes `--headless` (runs under Xvfb, for machines with no display).

What does and doesn't work there:

- **Mock mode is the normal way to use it.** `--mock` needs no Bluetooth at all
  and is the right choice for any UI work, and the only option in a container
  or VM.
- **Real BLE does work**, via BlueZ over D-Bus (`flutter_blue_plus_linux`). It
  needs a physical adapter with `bluetoothd` running; add yourself to the
  `bluetooth` group. Without an adapter, scans simply find nothing — the script
  warns when it can't see a controller.
- **`permission_handler` has no Linux implementation**, and nothing needs it to:
  `lib/services/real_ble_service.dart` only calls it on Android and every other
  platform falls through to "granted". BlueZ does the enforcing instead.
- The window opens phone-shaped (430x900) rather than the template's
  1280x720, since every screen is laid out for a phone. Resize it freely to
  check responsive behaviour.

## Testing

```bash
# Everything CI runs, in order
./scripts/test.sh

# Or individually:
flutter test                       # Dart unit + widget tests
cd rust && cargo test              # Rust unit tests

# Integration tests (needs a device/emulator). ci_all_test.dart bundles the
# mock-safe suites into ONE build+install+launch cycle — passing the whole
# integration_test/ directory instead runs each file as its own cycle (and
# would run the bundled suites twice).
flutter test integration_test/ci_all_test.dart

# Integration tests on the Linux desktop — no emulator, no display needed.
# One file per invocation on desktop (see docs/BUILD_AND_TEST.md):
xvfb-run -a flutter test integration_test/mock_flow_test.dart -d linux \
  --dart-define=LIBERATED_BREAD_MOCK=true
```

Linting:

```bash
flutter analyze --fatal-infos
cd rust && cargo clippy --all-targets -- -D warnings
```

Tests are not optional. They're a feature.

There is also a scripted screenshot walkthrough of the whole app
(`./scripts/e2e-walkthrough.sh`, macOS + iOS Simulator only, excluded from CI
via its `e2e` tag) — see [docs/BUILD_AND_TEST.md](docs/BUILD_AND_TEST.md).

See [docs/BUILD_AND_TEST.md](docs/BUILD_AND_TEST.md) for the full testing guide.

## FRB bindings

The Rust core is wired through `flutter_rust_bridge` 2.9.0. Generated bindings
live in `lib/src/rust/` and `rust/src/frb_generated.rs` — both are committed
(same reproducibility argument as `pubspec.lock`). CI fails if the bindings
are out of sync with the Rust API.

The native Rust library is built and bundled per platform by the `rust_builder`
flutter_rust_bridge plugin (cargokit), wired into Android (Gradle), iOS/macOS
(CocoaPods), and Linux/Windows (CMake). It compiles the `rust/` crate during
`flutter build`, so those builds need the Rust toolchain and the relevant
cross-compilation targets (see `scripts/setup.sh`).

`lib/main.dart` calls `RustLib.init()` at startup. Failures are caught so the
app still runs if the library can't be loaded (e.g. a host unit-test run
without the host library on the library path); `MockBleService` has a Dart-side
fallback whose byte output matches `rust/src/mock/simulator.rs` for the
example-bulb spec.

To regenerate the bindings after changing `rust/src/api/**`:

```bash
flutter_rust_bridge_codegen generate
```

For `flutter test` to exercise the Rust path, the host-target library must be
built and discoverable. From the repo root:

```bash
(cd rust && cargo build)
export LD_LIBRARY_PATH=$PWD/rust/target/debug
flutter test
```

On macOS, don't bother with the `DYLD_*` equivalents — the Flutter SDK's
`dart` binary uses the hardened runtime, which strips them. Instead the test
helper (`test/helpers/host_rust_lib.dart`) loads `rust/target/debug/<lib>` by
relative path (or the path in `LIBERATED_BREAD_RUST_LIB`), so building is
enough. `scripts/test.sh` handles all of this automatically.

## Project Structure

```
.
├── lib/
│   ├── main.dart               # Entry point
│   ├── app.dart                # App widget, routing, theme
│   ├── core/                   # Constants, theme, hex/uuid + HA helpers
│   ├── models/                 # IoTDevice, BleDiscoveredService, HA models
│   ├── providers/              # Riverpod providers (BLE, specs, spec packs, HA)
│   ├── screens/                # Scan, Device, HA settings, spec-pack settings
│   ├── services/               # BleService (real/mock), HA client, spec packs
│   ├── widgets/                # Control panel, raw + typed characteristic widgets
│   └── src/rust/               # Generated FRB bindings (committed, don't edit)
├── rust/
│   └── src/
│       ├── api/                # FFI boundary: device_api.rs, mock_api.rs
│       ├── codec/              # Binary encode/decode (types.rs)
│       ├── error.rs            # ProtocolError, SpecError
│       ├── mock/               # MockDeviceState simulator
│       ├── protocol/
│       │   ├── generic.rs      # YAML-driven GenericProtocol
│       │   ├── traits.rs       # DeviceProtocol trait
│       │   ├── dispatch.rs     # select_protocol() + spec cache
│       │   └── profiles/       # Standard BLE profiles (battery, device_info)
│       └── spec/               # YAML parser and type definitions
├── assets/
│   └── device_specs/           # Bundled fallback YAML device specs
├── integration_test/           # End-to-end flow tests (emulator, simulator,
│                               #   or Linux desktop via Xvfb)
├── test/                       # Dart unit + widget tests
├── scripts/
│   ├── setup.sh                # Full dev environment setup
│   ├── ci-versions.sh          # Toolchain versions, read out of ci.yml
│   ├── run.sh                  # Build and run with optional mock mode
│   ├── run-android.sh          # Boot the Android emulator + run
│   ├── run-ios.sh              # Boot the iOS Simulator + run (macOS)
│   ├── run-ios-device.sh       # Run on a paired physical iPhone (macOS)
│   ├── run-linux.sh            # Linux desktop — fastest loop, no emulator
│   ├── run-remote-mac.sh       # Linux → iPhone via a remote Mac over SSH
│   ├── e2e-walkthrough.sh      # Scripted screenshot walkthrough (macOS)
│   ├── e2e_shot_server.py      # Host-side screenshot server for the above
│   ├── verify_linux_bundle.sh  # Assert the Linux bundle really contains the Rust .so
│   └── test.sh                 # Local CI mirror (format, analyze, test, clippy)
└── docs/
    ├── WALKTHROUGH.md          # E2E architecture walkthrough
    ├── BUILD_AND_TEST.md       # Build, run, and test guide
    ├── BRANDING.md             # Palette + app-icon pipeline
    └── ios-from-linux.md       # iPhone workflows from a Linux machine
```

## Rust Core

The Rust core (`rust/src/`) provides protocol logic independent of Flutter:

- **Spec system** — Parses YAML device specifications into typed Rust structs.
- **Codec** — Encodes command parameters to bytes and decodes characteristic
  values from bytes, driven by format field definitions.
- **Protocol layer** — The `DeviceProtocol` trait with `GenericProtocol`
  (YAML-driven) and standard profile implementations.
- **Standard profiles** — Built-in controllers for Battery Service (0x180F)
  and Device Information (0x180A). No YAML needed.
- **Mock simulator** — Generates realistic fake BLE readings for each
  characteristic type.

## Device Specs

Device behavior is defined in YAML files under `assets/device_specs/`. Example:

```yaml
device:
  name: "Example Smart Bulb"
  manufacturer: "Acme Corp"
  manufacturer_status: "abandoned"
  protocol: "ble"
  identification:
    local_name_prefix: "ACME_"
    service_uuids:
      - "0000fff0-0000-1000-8000-00805f9b34fb"

services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control Service"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          power_on:
            description: "Turn on"
            value: [0x01, 0x01]
          set_brightness:
            description: "Set brightness level"
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: uint8
                min: 0
                max: 100
```

See [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md) for the full spec format
reference.

### Remote spec packs

The bundled specs are only the fallback catalog. The app can also download
**spec packs** at runtime, so new device support ships without waiting on an
app-store release:

- **What it fetches** — a JSON pack manifest of the shape
  `{"name": ..., "version": ..., "specs": ["bulb.yaml", ...]}`, each entry a
  filename resolved relative to the manifest URL. The default URL points at
  [opengreeniot-device-specs](https://github.com/PigsCanFlyLabs/opengreeniot-device-specs)'
  `pack.json` (`AppConstants.defaultSpecPackUrl` in `lib/core/constants.dart`);
  the user can override it, and the override persists in `SharedPreferences`.
- **How** — `lib/services/spec_pack_service.dart` does the fetching: requests
  are same-origin-only (redirects included), size-capped, and every downloaded
  spec is validated through the real Rust codec *before* install, so a spec
  that won't parse is rejected up front instead of silently skipped later.
  Installed packs are cached under the app documents directory at
  `spec_packs/<slug>/`. `lib/providers/spec_pack_provider.dart` drives it all.
- **UI** — the puzzle-piece icon in the scan screen's AppBar opens
  `SpecPackSettingsScreen`: install/refresh/remove packs, edit the URL.
- **Merging** — `deviceSpecsProvider` merges the bundled assets with every
  cached pack. Pack specs are namespaced `pack:<name>/<file>` so they can never
  collide with bundled keys, and a pack failure never removes a bundled spec.

The bundled fallback specs themselves are a hardcoded list in
`lib/providers/device_spec_provider.dart` (`AssetBundle` can't list a
directory). Adding a bundled spec means adding it there **and** updating the
expected-file assertion in `rust/tests/vendored_assets.rs`, which parses every
bundled spec through the real Rust parser.

## Mock Mode

Run with `--mock` to use simulated BLE devices without hardware:

```bash
./scripts/run.sh --mock
```

Mock mode provides two fake devices (ACME_Living_Room, ACME_Bedroom) with
Control Service and Battery Service. All byte-level simulation runs through the
Rust core, so the data flow is identical to real BLE — only the transport layer
is faked.

## Documentation

- [Architecture Walkthrough](docs/WALKTHROUGH.md) — E2E code walkthrough
- [Build & Test Guide](docs/BUILD_AND_TEST.md) — Setup, build, run, and test
- [Branding](docs/BRANDING.md) — Palette and app-icon pipeline
- [iOS from Linux](docs/ios-from-linux.md) — iPhone workflows without leaving Linux
- [Contributing](CONTRIBUTING.md) — How to contribute
- [Security Policy](SECURITY.md) — Vulnerability reporting
- [Changelog](CHANGELOG.md) — Release history

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and
PR guidelines.

## License

Apache 2.0 — Copyright 2026 Pigs Can Fly Labs LLC
