# OpenGreenIoT Mobile

[![CI](https://github.com/PigsCanFlyLabs/opengreeniot-mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/PigsCanFlyLabs/opengreeniot-mobile/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

> Because your phone should be able to talk to your smart lightbulb even after
> the manufacturer's servers have gone the way of the dodo.

A cross-platform **Flutter** app for communicating with Bluetooth Low Energy (BLE)
IoT devices via [OpenGreenIoT](https://github.com/PigsCanFlyLabs/opengreeniot)
by [Pigs Can Fly Labs LLC](https://pigscanfly.ca).

## Features

- Scan for nearby BLE devices
- Connect and browse GATT services/characteristics
- Read/write characteristic values
- Device-specific control panels (as we add them)

## Getting Started

```bash
flutter pub get
flutter run
```

## Test

```bash
flutter test
```

Tests are not optional. They're a feature.

## Architecture

```
lib/
├── main.dart           # Entry point
├── app.dart            # App widget & routing
├── core/               # Constants, theme
├── models/             # Data models
├── services/           # BLE service layer
└── screens/            # UI screens
```

## License

Apache 2.0 - Copyright 2026 Pigs Can Fly Labs LLC
