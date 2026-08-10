// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/services/device_manager.dart';

void main() {
  late DeviceManager manager;
  setUp(() {
    manager = DeviceManager();
  });

  IoTDevice makeDevice({String id = 'AA:BB:CC:DD:EE:FF', int rssi = -50}) {
    return IoTDevice(
        id: id,
        name: 'Test',
        rssi: rssi,
        isConnectable: true,
        discoveredAt: DateTime.now());
  }

  group('DeviceManager', () {
    test('starts empty', () {
      expect(manager.count, equals(0));
    });

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

  group('ghost expiry across scans', () {
    /// One full scan window in which only [seen] advertise.
    void scanWith(List<String> seen) {
      manager.beginScan();
      for (final id in seen) {
        manager.addOrUpdate(makeDevice(id: id));
      }
      manager.completeScan();
    }

    test('a device missing one scan survives — advertising is lossy', () {
      scanWith(['keeper', 'flaky']);
      scanWith(['keeper']);
      expect(manager.getById('flaky'), isNotNull,
          reason: 'one missed window must not evict a live device');
    });

    test('a device missing two consecutive scans is dropped', () {
      scanWith(['keeper', 'ghost']);
      scanWith(['keeper']);
      scanWith(['keeper']);
      expect(manager.getById('ghost'), isNull,
          reason: 'two full windows with no advertisement is a ghost');
      expect(manager.getById('keeper'), isNotNull);
    });

    test('reappearing resets the miss count', () {
      scanWith(['blinky']);
      scanWith([]); // miss 1
      scanWith(['blinky']); // back — slate wiped
      scanWith([]); // miss 1 again, not 2
      expect(manager.getById('blinky'), isNotNull);
      scanWith([]); // miss 2
      expect(manager.getById('blinky'), isNull);
    });

    test('an aborted scan charges no misses', () {
      scanWith(['keeper', 'ghost']);
      // Two scans start but never complete (error / user navigated away):
      // nothing learned, nothing dropped.
      manager.beginScan();
      manager.beginScan();
      expect(manager.getById('ghost'), isNotNull);
    });
  });
}
