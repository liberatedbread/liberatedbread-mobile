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

  /// A fixed instant to age devices against, so nothing here depends on how
  /// long the test itself took.
  final now = DateTime(2026, 8, 10, 12);

  IoTDevice makeDevice({
    String id = 'AA:BB:CC:DD:EE:FF',
    int rssi = -50,
    Duration ago = Duration.zero,
  }) {
    return IoTDevice(
      id: id,
      name: 'Test',
      rssi: rssi,
      isConnectable: true,
      discoveredAt: now.subtract(ago),
      lastSeen: now.subtract(ago),
    );
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

    test('addOrUpdate keeps the session\'s first discoveredAt', () {
      // Each scan invocation stamps first-seen from its own start, and the
      // scan restarts routinely (burst downshift, tab return, resume). Taking
      // the restarted scan's stamp would re-order same-band rows by
      // post-restart arrival — the reshuffle the discoveredAt tie-break
      // exists to prevent.
      final first = makeDevice(rssi: -60);
      manager.addOrUpdate(first);
      final rediscovered = IoTDevice(
        id: first.id,
        name: 'Test',
        rssi: -40,
        isConnectable: true,
        discoveredAt: now.add(const Duration(minutes: 2)),
        lastSeen: now.add(const Duration(minutes: 2)),
      );
      manager.addOrUpdate(rediscovered);

      final kept = manager.getById(first.id)!;
      expect(kept.discoveredAt, first.discoveredAt,
          reason: 'a restart does not make a known device newly discovered');
      expect(kept.rssi, -40, reason: 'everything else is the fresh sighting');
      expect(kept.lastSeen, rediscovered.lastSeen);
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

  group('freshness', () {
    test('a device just heard from is neither stale nor gone', () {
      final device = makeDevice();
      expect(DeviceManager.isStale(device, now), isFalse);
      expect(DeviceManager.isGone(device, now), isFalse);
    });

    test('a device quiet for less than the threshold is still live', () {
      // BLE advertising is lossy and sleepy sensors are slow; a short silence
      // must not put a warning on a device that is plainly still there.
      final device = makeDevice(ago: DeviceManager.staleAfter * 0.5);
      expect(DeviceManager.isStale(device, now), isFalse);
    });

    test('a device quiet past the threshold is stale but kept', () {
      final device = makeDevice(ago: DeviceManager.staleAfter);
      manager.addOrUpdate(device);

      expect(DeviceManager.isStale(device, now), isTrue);
      expect(DeviceManager.isGone(device, now), isFalse);
      expect(manager.forgetGone(now), isFalse);
      expect(manager.getById(device.id), isNotNull,
          reason: 'a warning, not an eviction: it is probably still there');
    });

    test('a device quiet past forgetAfter is dropped', () {
      manager
          .addOrUpdate(makeDevice(id: 'ghost', ago: DeviceManager.forgetAfter));
      manager.addOrUpdate(makeDevice(id: 'keeper'));

      expect(manager.forgetGone(now), isTrue);
      expect(manager.getById('ghost'), isNull,
          reason: 'a tap on it could only end in a connect timeout');
      expect(manager.getById('keeper'), isNotNull);
    });

    test('forgetGone reports nothing to do when everything is fresh', () {
      manager.addOrUpdate(makeDevice(id: '1'));
      manager.addOrUpdate(makeDevice(id: '2'));
      // The scan screen repaints on true, so a tick that changed nothing must
      // not claim it did.
      expect(manager.forgetGone(now), isFalse);
      expect(manager.count, 2);
    });

    test('being heard again clears the warning', () {
      manager
          .addOrUpdate(makeDevice(id: 'blinky', ago: DeviceManager.staleAfter));
      expect(manager.staleIds(now), {'blinky'});

      manager.addOrUpdate(makeDevice(id: 'blinky'));
      expect(manager.staleIds(now), isEmpty);
    });

    test('staleIds names exactly the devices past the threshold', () {
      manager.addOrUpdate(makeDevice(id: 'live'));
      manager
          .addOrUpdate(makeDevice(id: 'quiet', ago: DeviceManager.staleAfter));
      manager.addOrUpdate(
          makeDevice(id: 'quieter', ago: DeviceManager.staleAfter * 2));

      expect(manager.staleIds(now), {'quiet', 'quieter'});
    });

    test('the stale threshold sits well inside the forget one', () {
      // The two exist to say different things; collapsing them would mean a
      // device vanishing the moment it was flagged, with nothing to notice.
      expect(DeviceManager.staleAfter, lessThan(DeviceManager.forgetAfter));
    });
  });
}
