// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Exercises the Rust-backed read/write path through flutter_rust_bridge.
// Requires the host-target Rust library to be built and discoverable — the
// test uses the same `cargo build` + `LD_LIBRARY_PATH` that CI relies on.
// If initialization fails (e.g. running tests without a prior cargo build),
// the whole group is skipped via the `skip:` parameter on `main`.
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/services/mock_ble_service.dart';
import 'package:opengreeniot_mobile/src/rust/api/mock_api.dart' as rust;
import 'package:opengreeniot_mobile/src/rust/frb_generated.dart' show RustLib;

Future<bool> _initRust() async {
  try {
    await RustLib.init();
    return true;
  } catch (_) {
    return false;
  }
}

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
    rustReady = await _initRust();
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
  });
}
