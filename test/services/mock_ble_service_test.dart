// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/services/ble_service.dart';
import 'package:opengreeniot_mobile/services/mock_ble_service.dart';

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
    test('emits exactly 2 mock devices', () async {
      final devices = await service.scan().toList();
      expect(devices.length, 2);
    });

    test('emits devices with expected names', () async {
      final devices = await service.scan().toList();
      final names = devices.map((d) => d.name).toList();
      expect(names, contains('ACME_Living_Room'));
      expect(names, contains('ACME_Bedroom'));
    });

    test('emitted devices are connectable', () async {
      final devices = await service.scan().toList();
      expect(devices.every((d) => d.isConnectable), isTrue);
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
