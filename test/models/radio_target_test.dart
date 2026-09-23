// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';

void main() {
  group('RadioTransport', () {
    test('round-trips through its wire name', () {
      for (final transport in RadioTransport.values) {
        expect(RadioTransport.fromWire(transport.wireName), transport);
      }
    });

    test('an unknown wire name is null rather than a guess', () {
      expect(RadioTransport.fromWire('zigbee'), isNull);
      expect(RadioTransport.fromWire(null), isNull);
      expect(RadioTransport.fromWire(3), isNull);
    });

    test('reads naturally in a sentence', () {
      expect(RadioTransport.ble.overPhrase, 'over Bluetooth');
      expect(RadioTransport.usb.overPhrase, 'over a USB cable');
    });
  });

  group('RadioTarget', () {
    const ble = RadioTarget(
      transport: RadioTransport.ble,
      id: 'AA:BB',
      name: 'UV-5R Mini',
    );

    test('is identified by transport and id, not by name', () {
      expect(
        ble,
        const RadioTarget(
            transport: RadioTransport.ble, id: 'AA:BB', name: 'Renamed'),
      );
      expect(
          ble.hashCode,
          const RadioTarget(
                  transport: RadioTransport.ble, id: 'AA:BB', name: '')
              .hashCode);
    });

    test('the same id over another transport is another radio', () {
      expect(
        ble,
        isNot(const RadioTarget(
            transport: RadioTransport.usb, id: 'AA:BB', name: 'UV-5R Mini')),
      );
    });

    test('falls back to its id when it has no name to show', () {
      expect(ble.displayName, 'UV-5R Mini');
      expect(
        const RadioTarget(transport: RadioTransport.usb, id: 'COM3', name: '  ')
            .displayName,
        'COM3',
      );
    });
  });
}
