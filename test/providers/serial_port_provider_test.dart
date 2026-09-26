// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/serial_port_provider.dart';
import 'package:liberated_bread_mobile/services/android_usb_serial_service.dart';
import 'package:liberated_bread_mobile/services/desktop_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/mock_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/unsupported_serial_port_service.dart';

void main() {
  group('serialPortServiceFor', () {
    test('Android reaches cables through its USB host stack', () {
      expect(serialPortServiceFor('android'), isA<AndroidUsbSerialService>());
    });

    test('Linux and macOS go through the Rust core', () {
      expect(serialPortServiceFor('linux'), isA<DesktopSerialPortService>());
      expect(serialPortServiceFor('macos'), isA<DesktopSerialPortService>());
    });

    test('iOS says why it cannot', () {
      final service = serialPortServiceFor('ios');
      expect(service, isA<UnsupportedSerialPortService>());
      expect(service.availability.supported, isFalse);
      expect(
        service.availability.reason,
        UnsupportedSerialPortService.iosReason,
      );
    });

    test('anything else says it cannot, without claiming to be an iPhone', () {
      for (final os in ['windows', 'fuchsia', 'plan9']) {
        final service = serialPortServiceFor(os);
        expect(service.availability.supported, isFalse, reason: os);
        expect(
          service.availability.reason,
          UnsupportedSerialPortService.otherReason,
          reason: os,
        );
      }
    });

    test('demo mode has its cable on every platform', () {
      for (final os in ['android', 'ios', 'linux']) {
        expect(
          serialPortServiceFor(os, mock: true),
          isA<MockSerialPortService>(),
          reason: os,
        );
      }
    });
  });

  test('the provider serves this machine\'s service, and is overridable', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Whatever runs the tests is a real platform with an answer.
    expect(container.read(serialPortServiceProvider).availability, isNotNull);

    final mock = MockSerialPortService();
    final overridden = ProviderContainer(
      overrides: [serialPortServiceProvider.overrideWithValue(mock)],
    );
    addTearDown(overridden.dispose);
    expect(overridden.read(serialPortServiceProvider), same(mock));
  });
}
