// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// End-to-end check of a spec-driven temperature control: a vendored upstream
// CLIMATE entity, the real Rust codec over FFI, and the setpoint card the
// panel mounts for it. No fakes in the encode chain — the only thing that
// says "Hotwired" is the YAML. This is the shape every BLE temp control takes
// (a `climate` or `number` entity with a set_value action), so proving the
// vendored one drives the card end to end is what "ready for the next
// thermostat" means.
//
// Requires the host-target Rust library (cargo build + LD_LIBRARY_PATH, same
// as CI); tests are skipped if it isn't loaded.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/setpoint_control_card.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _commandChar = '0000ffb1-0000-1000-8000-00805f9b34fb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = RealSpecCodec();
  late final bool rustReady;
  late final String yaml;
  late final DeviceSpecDto spec;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    yaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/hotwired-heated-gear.yaml');
    if (rustReady) {
      spec = await codec.loadDeviceSpec(yaml);
    }
  });

  testWidgets('a vendored climate entity arrives with its bounds and action',
      (tester) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }

    final entity = spec.entities.firstWhere((e) => e.name == 'Heat Level');
    expect(entity.platform, 'climate');
    // min_temp/max_temp flow through the same setpoint fields min/max use,
    // so the card needs no climate-specific code to bound its slider.
    expect(entity.setpointMin, 0);
    expect(entity.setpointMax, 10);
    final action = entity.actions.where((a) => a.role == 'set_value');
    expect(action, hasLength(1),
        reason: 'the explicit set_value -> set_heat binding must resolve');
    expect(action.single.characteristicUuid, _commandChar);
  });

  testWidgets('dialling the card writes the real set_heat frame',
      (tester) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }

    final entity = spec.entities.firstWhere((e) => e.name == 'Heat Level');
    final ble = FakeBleService();
    final widget = ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SetpointControlCard(
              deviceId: 'd',
              // No readable state wired up: this exercises the write path,
              // which is the half a brand-new thermostat needs first.
              stateServiceUuid: null,
              entity: entity,
              specYaml: yaml,
            ),
          ),
        ),
      ),
    );

    // The real codec crosses into Rust on a background isolate, which the
    // widget-test binding's fake clock never advances — runAsync hands back
    // the real clock long enough for the encode to land.
    await tester.runAsync(() async {
      await tester.pumpWidget(widget);
      await tester.pump();

      // Drag the 0-10 slider hard right: full heat.
      await tester.drag(find.byType(Slider), const Offset(600, 0));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    // The spec's worked example for ON at level 10: AA 01 0A 00 00 00 00 55.
    // The bytes come out of the vendored template, not from any Dart code.
    expect(ble.writes, hasLength(1));
    expect(ble.writes.single.charUuid, _commandChar);
    expect(ble.writes.single.value,
        [0xAA, 0x01, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x55]);
  });
}
