// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';
import 'package:opengreeniot_mobile/services/device_manager.dart';

void main() {
  late DeviceManager manager;
  setUp(() { manager = DeviceManager(); });

  IoTDevice makeDevice({String id = 'AA:BB:CC:DD:EE:FF', int rssi = -50}) {
    return IoTDevice(id: id, name: 'Test', rssi: rssi, isConnectable: true, discoveredAt: DateTime.now());
  }

  group('DeviceManager', () {
    test('starts empty', () { expect(manager.count, equals(0)); });

    test('addOrUpdate adds a new device', () {
      manager.addOrUpdate(makeDevice());
      expect(manager.count, equals(1));
    });

    test('addOrUpdate updates existing device', () {
      manager.addOrUpdate(makeDevice(rssi: -80));
      manager.addOrUpdate(makeDevice(rssi: -40));
      expect(manager.count, equals(1));
      expect(manager.devices.first.rssi, equals(-40));
    });

    test('devices sorted by signal strength', () {
      manager.addOrUpdate(makeDevice(id: '1', rssi: -80));
      manager.addOrUpdate(makeDevice(id: '2', rssi: -40));
      manager.addOrUpdate(makeDevice(id: '3', rssi: -60));
      expect(manager.devices[0].id, equals('2'));
      expect(manager.devices[2].id, equals('1'));
    });

    test('getById returns null when not found', () {
      expect(manager.getById('nope'), isNull);
    });

    test('clear removes all', () {
      manager.addOrUpdate(makeDevice(id: '1'));
      manager.addOrUpdate(makeDevice(id: '2'));
      manager.clear();
      expect(manager.count, equals(0));
    });
  });
}
