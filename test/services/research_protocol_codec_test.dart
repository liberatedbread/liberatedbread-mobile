// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';

import '../helpers/host_rust_lib.dart';

const _orbaChar = '7772e5db-3868-4112-a1a9-f2669d106bf3';
const _mousrChar = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const _speedChar = 'af0a6ec7-0006-000c-84a0-91559fc6f0de';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final codec = RealSpecCodec();
  late final bool rustReady;
  late final String orbaYaml;
  late final String mousrYaml;
  late final String hotWheelsYaml;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    orbaYaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/artiphon-orba-2.yaml',
    );
    mousrYaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/petronics-mousr.yaml',
    );
    hotWheelsYaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/hot-wheels-id-race-portal.yaml',
    );
  });

  test(
    'Orba play crosses the real codec as the reference BLE-MIDI sequence',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final writes = await codec.encodeCommandWrites(
        specYaml: orbaYaml,
        charUuid: _orbaChar,
        commandName: 'transport_play',
        params: const {},
      );
      expect(writes, [
        [
          0x80,
          0x80,
          0xF0,
          0x00,
          0x02,
          0x03,
          0x00,
          0x00,
          0x50,
          0x60,
          0x40,
          0x03,
          0x00,
          0x04,
          0x14,
          0x00,
          0x7F,
          0x05,
        ],
        [0x80, 0x80, 0xF7],
      ]);
    },
  );

  test(
    'Orba FX write preserves its trailer across a fragment boundary',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final writes = await codec.encodeCommandWrites(
        specYaml: orbaYaml,
        charUuid: _orbaChar,
        commandName: 'set_bass_volume',
        params: const {'level': 128.0},
      );
      expect(writes, [
        [
          0x80,
          0x80,
          0xF0,
          0x00,
          0x02,
          0x03,
          0x00,
          0x00,
          0x00,
          0x61,
          0x00,
          0x01,
          0x50,
          0x20,
          0x00,
          0x04,
          0x10,
          0x00,
          0x41,
          0x2A,
        ],
        [0x80, 0x65, 0x01],
        [0x80, 0x80, 0xF7],
      ]);
    },
  );

  test('Mousr drive vector keeps fractional float32 values', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final writes = await codec.encodeCommandWrites(
      specYaml: mousrYaml,
      charUuid: _mousrChar,
      commandName: 'move',
      params: const {'speed': 0.5, 'hold': 0.25, 'angle': -1.5},
    );
    expect(writes.single, [
      0x30,
      0x00,
      0x00,
      0x00,
      0x3F,
      0x00,
      0x00,
      0x80,
      0x3E,
      0x00,
      0x00,
      0xC0,
      0xBF,
      0x30,
      0x32,
    ]);
  });

  test(
    'Hot Wheels speed decodes as a number without inventing a unit',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final values = await codec.decodeValue(
        specYaml: hotWheelsYaml,
        charUuid: _speedChar,
        bytes: const [0xB0, 0x1C, 0x14, 0x3E],
      );
      expect(values.single.name, 'speed_raw');
      expect(values.single.valueType, 'float');
      expect(values.single.rawNumber, closeTo(0.1446, 0.00005));
      expect(values.single.decodedNumber, closeTo(0.1446, 0.00005));
      expect(values.single.decodedText, '0.144641');
      expect(values.single.unit, isNull);
    },
  );
}
