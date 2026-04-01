# OpenGreenIoT Mobile

[![CI](https://github.com/PigsCanFlyLabs/opengreeniot-mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/PigsCanFlyLabs/opengreeniot-mobile/actions/workflows/ci.yml)
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
- Mock mode for development without BLE hardware
- Material Design 3 with light/dark themes

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Flutter | 3.24+ | Stable channel |
| Rust | stable (1.75+) | Via rustup |
| Android SDK | API 34 | With NDK 26.1 |
| Xcode | 15+ | macOS only, for iOS builds |
| CocoaPods | latest | macOS only |

## Quick Setup

The setup script installs everything (Flutter, Rust, Android SDK, FRB codegen):

```bash
./scripts/setup.sh
```

This works on **Linux** and **macOS** (both Intel and Apple Silicon). See
[docs/BUILD_AND_TEST.md](docs/BUILD_AND_TEST.md) for manual setup and
platform-specific details.

After setup, add Flutter to your PATH:

```bash
export PATH="$HOME/.flutter-sdk/bin:$PATH"
```

## Running the App

```bash
# Connected device or emulator
./scripts/run.sh

# Mock mode (no BLE hardware needed)
./scripts/run.sh --mock

# Manual (equivalent to run.sh --mock)
flutter run --dart-define=OPENGREENIOT_MOCK=true
```

## Testing

```bash
# Flutter tests
flutter test

# Rust tests
cd rust && cargo test

# Linting
flutter analyze
cd rust && cargo clippy
```

Tests are not optional. They're a feature.

See [docs/BUILD_AND_TEST.md](docs/BUILD_AND_TEST.md) for the full testing guide.

## Project Structure

```
.
├── lib/
│   ├── main.dart               # Entry point
│   ├── app.dart                # App widget, routing, theme
│   ├── core/                   # Constants, theme definitions
│   ├── models/                 # IoTDevice, DeviceCharacteristic, BleDiscoveredService
│   ├── providers/              # Riverpod providers (BLE, device specs, connection state)
│   ├── screens/                # ScanScreen, DeviceScreen, CharacteristicScreen
│   ├── services/               # BleService (abstract), RealBleService, MockBleService
│   └── widgets/                # DeviceControlPanel, RawCharacteristicWidget
├── rust/
│   └── src/
│       ├── api/                # FFI boundary: device_api.rs, mock_api.rs
│       ├── codec/              # Binary encode/decode (types.rs)
│       ├── error.rs            # ProtocolError, SpecError
│       ├── mock/               # MockDeviceState simulator
│       ├── protocol/
│       │   ├── generic.rs      # YAML-driven GenericProtocol
│       │   ├── traits.rs       # DeviceProtocol trait
│       │   ├── registry.rs     # ProtocolRegistry
│       │   ├── middleware.rs   # PassthroughMiddleware (skeleton)
│       │   └── profiles/       # Standard BLE profiles (battery, device_info)
│       └── spec/               # YAML parser and type definitions
├── assets/
│   └── device_specs/           # YAML device specification files
├── test/                       # Flutter unit tests
├── scripts/
│   ├── setup.sh                # Full dev environment setup
│   └── run.sh                  # Build and run with optional mock mode
└── docs/
    ├── WALKTHROUGH.md          # E2E architecture walkthrough
    └── BUILD_AND_TEST.md       # Build, run, and test guide
```

## Rust Core

The Rust core (`rust/src/`) provides protocol logic independent of Flutter:

- **Spec system** — Parses YAML device specifications into typed Rust structs.
  Each spec defines a device's BLE services, characteristics, commands, and
  data formats.
- **Codec** — Encodes command parameters to bytes and decodes characteristic
  values from bytes, driven by format field definitions.
- **Protocol layer** — The `DeviceProtocol` trait with `GenericProtocol`
  (YAML-driven) and standard profile implementations.
- **Standard profiles** — Built-in controllers for Battery Service (0x180F)
  and Device Information (0x180A). No YAML needed.
- **Registry** — Routes device specs and service UUIDs to the right protocol
  implementation.
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
- [Contributing](CONTRIBUTING.md) — How to contribute
- [Security Policy](SECURITY.md) — Vulnerability reporting
- [Changelog](CHANGELOG.md) — Release history

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and
PR guidelines.

## License

Apache 2.0 — Copyright 2026 Pigs Can Fly Labs LLC
