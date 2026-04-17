// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/device_characteristic.dart';

void main() {
  group('DeviceCharacteristic', () {
    test('hexValue formats bytes correctly', () {
      const c = DeviceCharacteristic(uuid: '0x2A19', value: [0x00, 0xFF, 0x0A]);
      expect(c.hexValue, equals('00 ff 0a'));
    });

    test('hexValue returns (empty) for empty value', () {
      const c = DeviceCharacteristic(uuid: '0x2A19');
      expect(c.hexValue, equals('(empty)'));
    });

    test('stringValue returns text for printable ASCII', () {
      const c = DeviceCharacteristic(
          uuid: '0x2A29', value: [0x48, 0x65, 0x6C, 0x6C, 0x6F]);
      expect(c.stringValue, equals('Hello'));
    });

    test('stringValue returns null for binary data', () {
      const c = DeviceCharacteristic(uuid: '0x2A19', value: [0x00, 0x01, 0x02]);
      expect(c.stringValue, isNull);
    });
  });
}
