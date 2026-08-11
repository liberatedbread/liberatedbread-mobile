# Liberated Bread Mobile

[![CI](https://github.com/liberatedbread/liberatedbread-mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/liberatedbread/liberatedbread-mobile/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/liberatedbread/liberatedbread-mobile/branch/main/graph/badge.svg)](https://codecov.io/gh/liberatedbread/liberatedbread-mobile)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

> Because your phone should be able to talk to your smart lightbulb even after
> the manufacturer's servers have gone the way of the dodo.

A cross-platform **Flutter + Rust** app for discovering and controlling
locally-controllable IoT devices — both **Bluetooth Low Energy (BLE)** and
**Wi-Fi/LAN** hardware — without the vendor cloud, built on
[OpenGreenIoT](https://github.com/PigsCanFlyLabs/opengreeniot) by
[Pigs Can Fly Labs LLC](https://pigscanfly.ca).

Half the catalogue is Wi-Fi hardware a Bluetooth scan can never see — bridges,
plugs, printers, TVs — so the app discovers devices on the local network
(mDNS/DNS-SD and SSDP/UPnP) alongside the BLE scan and drives them over HTTP and
SOAP, all from the same YAML device specs.

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

**Flutter** handles the UI, the BLE and local-network (mDNS/SSDP) transports,
and permissions.
**Rust** handles protocol logic: parsing YAML device specs, encoding commands,
decoding characteristic values, implementing standard Bluetooth profiles, and
rendering the HTTP/SOAP requests that drive Wi-Fi/LAN devices.

## Features

- Scan for nearby **BLE** devices *and* discover **Wi-Fi/LAN** devices on the
  local network (mDNS/DNS-SD + SSDP/UPnP) from the same screen — each ranked by
  how well the catalogue recognises it and labelled with what kind of device it
  is (light, sensor, motor, switch, display, TV, lock, …)
- Connect and browse GATT services/characteristics
- Read/write characteristic values with hex display
- Control Wi-Fi/LAN devices over HTTP and SOAP — the same spec-driven typed
  controls as the BLE path, generated straight from the YAML
- Standard BLE profile support (Battery Service, Device Information)
- YAML-driven device specs for custom IoT protocols
- Spec-driven typed device controls (buttons, sliders, decoded values —
  generated straight from the YAML)
- Downloadable remote spec packs — new device support without an app update
- Find Device view — hot/cold locator with live signal strength, a rough
  distance guess, and one-tap beep/flash buttons on devices that support them
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
| Android emulator | API 34 `aosp_atd` x86-64 | Needs KVM on Linux; `./scripts/setup.sh` creates the AVD. `aosp_atd` is Google's CI image — no launcher or Play Services, which is what CI wants; `flutter run` starts the activity directly so it works locally too |

What the built app runs on, as opposed to what builds it: Android 7.0
(API 24), iOS 13, macOS 10.15. Those are the floors the pinned Flutter
supports, and `test/platform/deployment_targets_test.dart` fails if the files
declaring them ever disagree.

The exact versions live in `.github/workflows/ci.yml` and are read from there by
`scripts/ci-versions.sh` — the table is a summary, that command is the answer.

For the **Linux desktop** target (`./scripts/run-linux.sh`), `./scripts/setup.sh`
installs the native toolchain for you on apt-based distros; to do it by hand:

```bash
eval "$(./scripts/ci-versions.sh)"   # the list CI installs, xvfb included
sudo apt-get update && sudo apt-get install -y --no-install-recommends \
  ${CI_LINUX_DESKTOP_PACKAGES}
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
# One file per invocation here (a flutter_tools VM-service bug; see
# docs/BUILD_AND_TEST.md), skipping the device-jobs aggregate:
for t in integration_test/*_test.dart; do
  [ "$(basename "$t")" = ci_all_test.dart ] && continue
  xvfb-run -a flutter test "$t" -d linux --exclude-tags=e2e \
    --dart-define=LIBERATED_BREAD_MOCK=true
done
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
built. **This happens on its own** — `test/helpers/host_rust_lib.dart` compares
the built library against cargo's own record of what went into it and runs
`cargo build` when it is missing or out of date, so editing `rust/src/` and
re-running the tests tests the edit:

```bash
flutter test
./scripts/ensure-rust-lib.sh   # or build it yourself, ahead of time
```

That is not a convenience. These suites `markTestSkipped` when the library will
not load, so *no* build and a *stale* build both used to report green — the
first with a quietly smaller suite, the second by testing the previous version
of the Rust code. Set `LIBERATED_BREAD_NO_RUST_BUILD=1` to opt out, or point
`LIBERATED_BREAD_RUST_LIB` at an artifact you built yourself.

No `LD_LIBRARY_PATH` is needed, and on macOS the `DYLD_*` equivalents do not
work at all — the Flutter SDK's `dart` binary uses the hardened runtime, which
strips them. The helper loads `rust/target/debug/<lib>` by relative path
instead, so building is the whole requirement.

## Project Structure

```
.
├── lib/
│   ├── main.dart               # Entry point
│   ├── app.dart                # App widget, routing, theme
│   ├── core/                   # Constants, theme, hex/uuid + HA helpers
│   ├── models/                 # IoTDevice, BleDiscoveredService, HA models
│   ├── providers/              # Riverpod providers (BLE, specs, spec packs, HA)
│   ├── screens/                # BLE + Wi-Fi scan, Device, Find device, HA + spec-pack settings
│   ├── services/               # BLE + network scan (mDNS/SSDP), HTTP/SOAP control, HA, spec packs
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
│       │   ├── http.rs         # HTTP transport for Wi-Fi/LAN devices
│       │   ├── soap.rs         # SOAP/UPnP transport (Wemo, older bridges)
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

Device behavior is defined in YAML files, bundled straight out of the vendored
protocol-specs subtree at `vendor/protocol-specs/device-specs/`. There is no
copy under `assets/`: the subtree is the single source of truth, so refreshing
the catalogue is `git subtree pull`, not a sync step — run it through
`./scripts/update-specs.sh`, which wraps the ordinary subtree commands and then
checks that everything `pubspec.yaml` bundles actually arrived. Specs are
vendored unmodified: edit them in
[liberatedbread-protocol-specs](https://github.com/liberatedbread/liberatedbread-protocol-specs)
and refresh, never in place here. Example:

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
    # Optional, and both are used to rank scan results before connecting.
    # A MAC OUI identifies a vendor rather than a product, so it only ever
    # promotes a device up the list — it never claims one is supported.
    manufacturer_data:
      company_id: 961
    mac_prefixes: ["C4:7C:8D"]

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

The example above is a BLE spec. A Wi-Fi/LAN device instead declares
`protocol: wifi`, is identified by its mDNS service type or SSDP search target,
and carries `http`/`soap` transport blocks that say how each command is sent —
the app renders and issues those requests through the Rust core, exactly as it
encodes GATT writes for BLE.

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
