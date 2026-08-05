// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/mock_ble_service.dart';

void main() {
  late MockBleService service;

  setUp(() {
    service = MockBleService();
  });

  group('permissions', () {
    test('requestPermissions always returns true', () async {
      expect(await service.requestPermissions(), isTrue);
    });
  });

  group('scan', () {
    test('emits exactly 4 mock devices', () async {
      final devices = await service.scan().toList();
      expect(devices.length, 4);
    });

    test('emits devices with expected names', () async {
      final devices = await service.scan().toList();
      final names = devices.map((d) => d.name).toList();
      expect(names, contains('ACME_Living_Room'));
      expect(names, contains('ACME_Bedroom'));
      // A device backed by a different vendored spec, so demo mode exercises
      // more than one shape of catalogue entry.
      expect(names, contains('Airthings Wave Plus'));
    });

    test('emitted devices are connectable', () async {
      final devices = await service.scan().toList();
      expect(devices.every((d) => d.isConnectable), isTrue);
    });

    // Demo mode has to produce every rung of the scan-time confidence ladder,
    // otherwise the ranked device list can only ever be seen against real
    // hardware.
    test('mock advertisements cover every identification signal', () async {
      final devices = await service.scan().toList();
      final byId = {for (final d in devices) d.id: d};

      expect(byId['AA:BB:CC:DD:EE:01']!.serviceUuids,
          contains('0000fff0-0000-1000-8000-00805f9b34fb'),
          reason: 'one device must advertise a service UUID');
      expect(byId['AA:BB:CC:DD:EE:02']!.serviceUuids, isEmpty,
          reason: 'one device must be recognisable by name alone');
      expect(byId['AA:BB:CC:DD:EE:03']!.companyIds, contains(820),
          reason: 'one device must be recognisable by company ID alone');

      final anonymous = byId['C4:7C:8D:11:22:04']!;
      expect(anonymous.name, isEmpty);
      expect(anonymous.serviceUuids, isEmpty);
      expect(anonymous.companyIds, isEmpty);
      expect(anonymous.macAddress, 'C4:7C:8D:11:22:04',
          reason: 'one device must be identifiable only by its OUI');
    });
  });

  group('connect / disconnect', () {
    test('connect emits connected state', () async {
      final states = <BleConnectionState>[];
      service.connectionState('AA:BB:CC:DD:EE:01').listen(states.add);

      await service.connect('AA:BB:CC:DD:EE:01');
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(BleConnectionState.connected));
    });

    test('disconnect emits disconnected state', () async {
      final states = <BleConnectionState>[];
      service.connectionState('AA:BB:CC:DD:EE:01').listen(states.add);

      await service.connect('AA:BB:CC:DD:EE:01');
      await service.disconnect('AA:BB:CC:DD:EE:01');
      await Future<void>.delayed(Duration.zero);

      expect(states.last, BleConnectionState.disconnected);
    });
  });

  group('dispose', () {
    test('closes connection-state streams so they do not leak', () async {
      var done = false;
      // Listening to a connection stream lazily creates its controller.
      final subscription = service
          .connectionState('AA:BB:CC:DD:EE:01')
          .listen((_) {}, onDone: () => done = true);
      await service.connect('AA:BB:CC:DD:EE:01');
      await Future<void>.delayed(Duration.zero);

      await service.dispose();
      await Future<void>.delayed(Duration.zero);

      // A closed broadcast controller completes its listeners with onDone.
      expect(done, isTrue);
      await subscription.cancel();
    });

    test('is safe to call twice', () async {
      service.connectionState('AA:BB:CC:DD:EE:01').listen((_) {});
      await service.connect('AA:BB:CC:DD:EE:01');
      await service.dispose();
      // Second call must not throw even though controllers are already closed.
      await service.dispose();
    });

    test('stops an active notify subscription from emitting', () async {
      await service.connect('AA:BB:CC:DD:EE:01');

      final emitted = <List<int>>[];
      var done = false;
      final subscription = service
          .subscribeCharacteristic(
            'AA:BB:CC:DD:EE:01',
            '0000180f-0000-1000-8000-00805f9b34fb',
            '00002a19-0000-1000-8000-00805f9b34fb',
          )
          .listen(emitted.add, onDone: () => done = true);

      // Wait for the first periodic notification so the machinery is live.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(emitted, isNotEmpty);

      await service.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue);

      // No further emissions after dispose, even across another timer period.
      final countAtDispose = emitted.length;
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(emitted.length, countAtDispose);

      await subscription.cancel();
    });
  });

  group('discoverServices', () {
    test('returns services for known device', () async {
      final services = await service.discoverServices('AA:BB:CC:DD:EE:01');
      expect(services.length, 2);
    });

    test('throws for unknown device', () async {
      expect(
        () => service.discoverServices('unknown'),
        throwsStateError,
      );
    });

    test('services contain expected UUIDs', () async {
      final services = await service.discoverServices('AA:BB:CC:DD:EE:01');
      final uuids = services.map((s) => s.uuid).toSet();
      expect(uuids, contains('0000fff0-0000-1000-8000-00805f9b34fb'));
      expect(uuids, contains('0000180f-0000-1000-8000-00805f9b34fb'));
    });
  });

  group('readCharacteristic', () {
    test('returns default battery value', () async {
      final value = await service.readCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000180f-0000-1000-8000-00805f9b34fb',
        '00002a19-0000-1000-8000-00805f9b34fb',
      );
      expect(value, [85]); // 85% battery
    });

    test('returns default status value', () async {
      final value = await service.readCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000fff0-0000-1000-8000-00805f9b34fb',
        '0000fff2-0000-1000-8000-00805f9b34fb',
      );
      expect(value, [1, 80, 255, 180, 50]);
    });

    test('returns [0] for unknown characteristic', () async {
      final value = await service.readCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000fff0-0000-1000-8000-00805f9b34fb',
        '00009999-0000-1000-8000-00805f9b34fb',
      );
      expect(value, [0]);
    });
  });

  group('writeCharacteristic then readCharacteristic', () {
    test('returns written value', () async {
      await service.writeCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000fff0-0000-1000-8000-00805f9b34fb',
        '0000fff1-0000-1000-8000-00805f9b34fb',
        [0x01, 0x50],
      );

      final value = await service.readCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000fff0-0000-1000-8000-00805f9b34fb',
        '0000fff1-0000-1000-8000-00805f9b34fb',
      );
      expect(value, [0x01, 0x50]);
    });

    test('writes are isolated per device', () async {
      await service.writeCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000fff0-0000-1000-8000-00805f9b34fb',
        '0000fff1-0000-1000-8000-00805f9b34fb',
        [0x01],
      );

      // Different device should not see the write
      final value = await service.readCharacteristic(
        'AA:BB:CC:DD:EE:02',
        '0000fff0-0000-1000-8000-00805f9b34fb',
        '0000fff1-0000-1000-8000-00805f9b34fb',
      );
      expect(value, [0]); // default, not [0x01]
    });
  });

  group('subscribeCharacteristic', () {
    test('emits values when connected', () async {
      await service.connect('AA:BB:CC:DD:EE:01');

      final stream = service.subscribeCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000180f-0000-1000-8000-00805f9b34fb',
        '00002a19-0000-1000-8000-00805f9b34fb',
      );

      // Take first emission (timer fires at 2s intervals)
      final first = await stream.first.timeout(
        const Duration(seconds: 5),
      );
      expect(first, [85]); // default battery

      await service.disconnect('AA:BB:CC:DD:EE:01');
    });
  });
}
