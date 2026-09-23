// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_programmer_provider.dart';
import 'package:liberated_bread_mobile/providers/serial_port_provider.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/mock_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/serial_radio_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_radio_programmer.dart';

void main() {
  test('provides a real programmer over the app\'s BLE service', () {
    final container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(FakeBleService()),
    ]);
    addTearDown(container.dispose);

    final programmer = container.read(radioProgrammerProvider);
    // Demo mode is a compile-time define, so under test this is the real
    // driver -- which is the arrangement worth pinning: the mock must not
    // reach a shipping build by accident.
    expect(isMockMode, isFalse);
    expect(programmer, isA<BaofengBleProgrammer>());
  });

  test('is overridable, which is how the screens are tested', () {
    final fake = FakeRadioProgrammer();
    final container = ProviderContainer(overrides: [
      radioProgrammerProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);
    expect(container.read(radioProgrammerProvider), same(fake));
    expect(fake, isA<RadioProgrammer>());
  });

  group('radioProgrammerForTransportProvider', () {
    test('Bluetooth is the Bluetooth programmer, overrides included', () {
      final fake = FakeRadioProgrammer();
      final container = ProviderContainer(overrides: [
        radioProgrammerProvider.overrideWithValue(fake),
      ]);
      addTearDown(container.dispose);
      expect(
        container.read(radioProgrammerForTransportProvider(RadioTransport.ble)),
        same(fake),
      );
    });

    test('a cable gets the cable driver, never the Bluetooth one', () {
      final container = ProviderContainer(overrides: [
        radioProgrammerProvider.overrideWithValue(FakeRadioProgrammer()),
        serialPortServiceProvider.overrideWithValue(MockSerialPortService()),
      ]);
      addTearDown(container.dispose);
      final cable = container
          .read(radioProgrammerForTransportProvider(RadioTransport.usb));

      expect(cable, isA<SerialRadioProgrammer>(),
          reason: 'a port name must never reach the Bluetooth driver');
      expect(cable.supports(uv5rProfile), isTrue);
      expect(cable.supports(uv5rMiniProfile), isFalse);
    });

    test('the cable driver is overridable on its own', () {
      final fake = FakeRadioProgrammer();
      final container = ProviderContainer(overrides: [
        serialRadioProgrammerProvider.overrideWithValue(fake),
      ]);
      addTearDown(container.dispose);
      expect(
        container.read(radioProgrammerForTransportProvider(RadioTransport.usb)),
        same(fake),
      );
    });
  });

  test('the decoder is the native one unless a test says otherwise', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(codeplugDecoderProvider), isA<CodeplugDecoder>());
  });
}
