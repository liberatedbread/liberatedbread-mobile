// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Exercises the Rust-backed read/write path through flutter_rust_bridge.
// Requires the host-target Rust library to be built and discoverable — the
// test uses the same `cargo build` + `LD_LIBRARY_PATH` that CI relies on.
// If initialization fails (e.g. running tests without a prior cargo build),
// the whole group is skipped via the `skip:` parameter on `main`.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/mock_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/mock_api.dart' as rust;

import '../helpers/host_rust_lib.dart';

const _bulbYaml = '''
device:
  name: Test
  manufacturer: Test
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: 0000180f-0000-1000-8000-00805f9b34fb
    name: Battery
    characteristics:
      - uuid: 00002a19-0000-1000-8000-00805f9b34fb
        name: Battery Level
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: battery_percent
            type: uint8
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  group('FRB round-trip', () {
    test('mockWrite then mockRead returns the written bytes', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      await rust.mockReset();
      const deviceId = 'dev1';
      const charUuid = '00002a19-0000-1000-8000-00805f9b34fb';
      await rust.mockWriteCharacteristic(
        deviceId: deviceId,
        charUuid: charUuid,
        value: [42],
      );
      final read = await rust.mockReadCharacteristic(
        deviceId: deviceId,
        charUuid: charUuid,
        specYaml: _bulbYaml,
      );
      expect(read, [42]);
    });

    test('MockBleService reads match the Rust simulator default', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      await rust.mockReset();
      expect(MockBleService.rustAvailable, isTrue);
      final svc = MockBleService(loadSpec: () async => _bulbYaml);
      final bytes = await svc.readCharacteristic(
        'AA:BB:CC:DD:EE:01',
        '0000180f-0000-1000-8000-00805f9b34fb',
        '00002a19-0000-1000-8000-00805f9b34fb',
      );
      // simulator.rs `default_uint8_for_name("battery_percent")` returns 85.
      expect(bytes, [85]);
    });

    test('mock GATT tree is derived from the spec, not written into the app',
        () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      await rust.mockReset();
      // Every mock device resolves through the same loader, so handing back one
      // spec makes each of them advertise that spec's services. The point is
      // that the tree comes out of the YAML at all: nothing here is declared in
      // Dart.
      final svc = MockBleService(loadAsset: (_) async => _bulbYaml);
      final services = await svc.discoverServices('AA:BB:CC:DD:EE:01');

      expect(services, hasLength(1));
      expect(services.single.uuid, '0000180f-0000-1000-8000-00805f9b34fb');
      final char = services.single.characteristics.single;
      expect(char.uuid, '00002a19-0000-1000-8000-00805f9b34fb');
      expect(char.canRead, isTrue);
      expect(char.canWrite, isFalse);
    });

    test('a mock device backed by a different spec reads through that spec',
        () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      await rust.mockReset();
      // The Airthings mock exists to prove demo mode is not bulb-shaped: its
      // temperature is int16 with `scale: 0.01`, so the simulator must produce
      // the raw count for ~22 °C rather than the unscaled default.
      final svc = MockBleService();
      final bytes = await svc.readCharacteristic(
        'AA:BB:CC:DD:EE:03',
        '0000181a-0000-1000-8000-00805f9b34fb',
        '00002a6e-0000-1000-8000-00805f9b34fb',
      );
      expect(bytes, [2200 & 0xFF, 2200 >> 8]);
    });
  });
}
