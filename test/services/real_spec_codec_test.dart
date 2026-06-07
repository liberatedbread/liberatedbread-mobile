// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Exercises the real flutter_rust_bridge path through [RealSpecCodec] against
// the bundled example spec. Requires the host-target Rust library (cargo build
// + LD_LIBRARY_PATH, same as CI); the group is skipped if it isn't loaded.
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/services/real_spec_codec.dart';
import 'package:opengreeniot_mobile/src/rust/frb_generated.dart' show RustLib;

const _cmdChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const _statusChar = '0000fff2-0000-1000-8000-00805f9b34fb';

Future<bool> _initRust() async {
  try {
    await RustLib.init();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = RealSpecCodec();
  late final bool rustReady;
  late final String yaml;

  setUpAll(() async {
    rustReady = await _initRust();
    yaml = await rootBundle.loadString('assets/device_specs/example-bulb.yaml');
  });

  test('loadDeviceSpec parses the bundled bulb spec', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final spec = await codec.loadDeviceSpec(yaml);
    expect(spec.deviceName, 'Example Smart Bulb');
    expect(spec.localNamePrefix, 'ACME_');

    final control =
        spec.services.firstWhere((s) => s.name == 'Control Service');
    final command = control.characteristics.first;
    expect(
      command.commands.map((c) => c.name),
      containsAll(<String>['power_on', 'set_brightness']),
    );
    expect(
      command.commands.firstWhere((c) => c.name == 'power_on').isFixed,
      isTrue,
    );
    final setBrightness =
        command.commands.firstWhere((c) => c.name == 'set_brightness');
    expect(setBrightness.isFixed, isFalse);
    expect(setBrightness.parameters.single.name, 'brightness');
  });

  test('encodeCommand produces the spec-defined bytes', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final powerOn = await codec.encodeCommand(
      specYaml: yaml,
      charUuid: _cmdChar,
      commandName: 'power_on',
      params: const {},
    );
    expect(powerOn, [1, 1]);

    final setBrightness = await codec.encodeCommand(
      specYaml: yaml,
      charUuid: _cmdChar,
      commandName: 'set_brightness',
      params: const {'brightness': 50.0},
    );
    expect(setBrightness, [2, 50]);
  });

  test('decodeValue names the status fields', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final decoded = await codec.decodeValue(
      specYaml: yaml,
      charUuid: _statusChar,
      bytes: const [1, 80, 255, 180, 50],
    );
    final byName = {for (final d in decoded) d.name: d};
    expect(
      byName.keys,
      containsAll(
          <String>['power_state', 'brightness', 'red', 'green', 'blue']),
    );
    expect(byName['brightness']!.uintValue, 80);
  });

  test('matchDeviceToSpec matches by name prefix', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final spec = await codec.loadDeviceSpec(yaml);
    final matches = await codec.matchDeviceToSpec(
      specs: [spec],
      deviceName: 'ACME_Living_Room',
      advertisedServiceUuids: const [],
    );
    expect(matches, isNotEmpty);
    expect(matches.first.matchedByNamePrefix, isTrue);
  });
}
