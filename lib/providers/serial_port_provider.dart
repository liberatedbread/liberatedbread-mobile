// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/android_usb_serial_service.dart';
import '../services/desktop_serial_port_service.dart';
import '../services/mock_serial_port_service.dart';
import '../services/serial_port_service.dart';
import '../services/unsupported_serial_port_service.dart';
import 'ble_provider.dart' show isMockMode;

/// The serial service for an operating system, by its
/// [Platform.operatingSystem] name.
///
/// A function of the name rather than of [Platform] itself so every branch
/// can be tested from whichever machine runs the tests.
SerialPortService serialPortServiceFor(
  String operatingSystem, {
  bool mock = false,
}) {
  if (mock) return MockSerialPortService();
  return switch (operatingSystem) {
    'android' => AndroidUsbSerialService(),
    'linux' || 'macos' => DesktopSerialPortService(),
    'ios' => const UnsupportedSerialPortService(
        UnsupportedSerialPortService.iosReason),
    _ => const UnsupportedSerialPortService(
        UnsupportedSerialPortService.otherReason),
  };
}

/// The serial ports this platform has — or, where it has none, a service
/// that says why.
///
/// Demo mode gets its always-plugged-in cable, for the same reason the BLE
/// service has a mock: demo mode is a shipped feature, not a test double.
final serialPortServiceProvider = Provider<SerialPortService>(
  (ref) => serialPortServiceFor(Platform.operatingSystem, mock: isMockMode),
);
