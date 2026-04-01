// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot/models/ble_discovered_service.dart';

void main() {
  group('BleDiscoveredService', () {
    test('stores uuid and characteristics', () {
      const service = BleDiscoveredService(
        uuid: '0000180f-0000-1000-8000-00805f9b34fb',
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: '00002a19-0000-1000-8000-00805f9b34fb',
            canRead: true,
            canWrite: false,
            canNotify: true,
          ),
        ],
      );
      expect(service.uuid, '0000180f-0000-1000-8000-00805f9b34fb');
      expect(service.characteristics.length, 1);
    });

    test('supports const construction', () {
      // Verifies const constructors compile and work
      const service = BleDiscoveredService(
        uuid: 'test',
        characteristics: [],
      );
      expect(service.characteristics, isEmpty);
    });
  });

  group('BleDiscoveredCharacteristic', () {
    test('stores all properties', () {
      const char = BleDiscoveredCharacteristic(
        uuid: '00002a19-0000-1000-8000-00805f9b34fb',
        canRead: true,
        canWrite: false,
        canNotify: true,
      );
      expect(char.uuid, '00002a19-0000-1000-8000-00805f9b34fb');
      expect(char.canRead, isTrue);
      expect(char.canWrite, isFalse);
      expect(char.canNotify, isTrue);
    });

    test('write-only characteristic', () {
      const char = BleDiscoveredCharacteristic(
        uuid: '0000fff1-0000-1000-8000-00805f9b34fb',
        canRead: false,
        canWrite: true,
        canNotify: false,
      );
      expect(char.canRead, isFalse);
      expect(char.canWrite, isTrue);
      expect(char.canNotify, isFalse);
    });
  });
}
