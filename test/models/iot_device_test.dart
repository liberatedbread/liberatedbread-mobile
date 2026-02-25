// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';

void main() {
  group('IoTDevice', () {
    test('isNearby returns true when RSSI is strong', () {
      final device = IoTDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Test', rssi: -50, isConnectable: true, discoveredAt: DateTime.now());
      expect(device.isNearby, isTrue);
    });

    test('isNearby returns false when RSSI is weak', () {
      final device = IoTDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'Test', rssi: -90, isConnectable: true, discoveredAt: DateTime.now());
      expect(device.isNearby, isFalse);
    });

    test('displayName falls back to ID when name is empty', () {
      final device = IoTDevice(id: 'AA:BB:CC:DD:EE:FF', name: '', rssi: -50, isConnectable: true, discoveredAt: DateTime.now());
      expect(device.displayName, equals('Unknown (AA:BB:CC:DD:EE:FF)'));
    });

    test('equality is based on id', () {
      final now = DateTime.now();
      final d1 = IoTDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'A', rssi: -50, isConnectable: true, discoveredAt: now);
      final d2 = IoTDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'B', rssi: -80, isConnectable: false, discoveredAt: now);
      expect(d1, equals(d2));
    });

    test('different ids are not equal', () {
      final now = DateTime.now();
      final d1 = IoTDevice(id: '11:22:33:44:55:66', name: 'A', rssi: -50, isConnectable: true, discoveredAt: now);
      final d2 = IoTDevice(id: 'AA:BB:CC:DD:EE:FF', name: 'A', rssi: -50, isConnectable: true, discoveredAt: now);
      expect(d1, isNot(equals(d2)));
    });
  });
}
