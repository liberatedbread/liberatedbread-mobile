// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// End-to-end check of spec-driven rendering: a vendored upstream spec, the real
// Rust codec over FFI, and the widget that turns the result into a reading. No
// fakes and no device-specific code anywhere in the chain — the only thing that
// says "Airthings" is the YAML.
//
// Requires the host-target Rust library (cargo build + DYLD_FALLBACK_LIBRARY_PATH,
// same as CI); tests are skipped if it isn't loaded.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/entity_sensor_card.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _envSensing = '0000181a-0000-1000-8000-00805f9b34fb';
const _tempChar = '00002a6e-0000-1000-8000-00805f9b34fb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = RealSpecCodec();
  late final bool rustReady;
  late final String yaml;
  late final DeviceSpecDto spec;
  late final String gerbingYaml;
  late final DeviceSpecDto gerbing;

  // Every spec is parsed here, never inside a test body. `loadDeviceSpec`
  // crosses into Rust on a background isolate, and the widget-test binding's
  // fake clock does not advance for it — an await on one inside a test hangs
  // until the ten-minute timeout rather than resolving.
  setUpAll(() async {
    rustReady = await initHostRustLib();
    yaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/airthings-wave-family.yaml');
    gerbingYaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/gerbing-thermogauge.yaml');
    if (rustReady) {
      spec = await codec.loadDeviceSpec(yaml);
      gerbing = await codec.loadDeviceSpec(gerbingYaml);
    }
  });

  testWidgets('renders a vendored spec\'s temperature in degrees, not counts',
      (tester) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }

    final entity = spec.entities.firstWhere((e) => e.name == 'Temperature');
    // The reading only works because the spec resolves to the declaration that
    // carries the byte layout: this UUID is declared twice in the spec, and the
    // first occurrence is a bare stub.
    expect(entity.hasFormat, isTrue);
    expect(entity.stateCharacteristic, _tempChar);

    final widget = ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(
          FakeBleService(readValues: const {
            // 2350 as little-endian int16: 23.5 °C in the hundredths the
            // Bluetooth SIG characteristic reports.
            _tempChar: [0x2E, 0x09],
          }),
        ),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntitySensorCard(
            deviceId: 'd',
            serviceUuid: _envSensing,
            entity: entity,
            specYaml: yaml,
          ),
        ),
      ),
    );

    // The real codec crosses into Rust on a background isolate, which the test
    // binding's fake clock never advances. `runAsync` hands back the real one
    // for long enough to let the decode land; `pumpAndSettle` alone would just
    // spin the loading indicator until it times out.
    await tester.runAsync(() async {
      await tester.pumpWidget(widget);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(find.text('23.50'), findsOneWidget);
    expect(find.text('2350'), findsNothing);
    expect(find.text('°C'), findsOneWidget);
  });

  testWidgets('every entity the spec declares resolves to a decodable reading',
      (tester) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }

    expect(spec.entities, hasLength(6));
    // An entity that crosses the FFI boundary without a format block renders as
    // "cannot be decoded", which is honest but useless. For this device the
    // whole set should be live.
    expect(spec.entities.every((e) => e.hasFormat), isTrue);
  });

  testWidgets('renders an OFFSET scaling from a vendored spec, not raw counts',
      (tester) async {
    // The Airthings case above is a pure multiplier, which is the half of the
    // transform the card always applied. This one is the half it dropped:
    // gerbing-thermogauge declares `scale: 0.5, value_offset: 85` on its
    // temperature field, and the offset went missing between the codec and
    // the screen. A raw 100 rendered as "50.0" — wrong by the entire offset,
    // and wrong in the direction that still looks like a temperature, so
    // nothing about the reading said it was broken.
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }

    const service = 'ab06bd90-cc16-11e4-8830-0800200c9a66';
    const tempChar = 'ab06bd91-cc16-11e4-8830-0800200c9a66';
    final entity =
        gerbing.entities.firstWhere((e) => e.name == 'Temperature 1');
    expect(entity.stateCharacteristic, tempChar);

    final widget = ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(
          FakeBleService(readValues: const {
            tempChar: [100],
          }),
        ),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntitySensorCard(
            deviceId: 'd',
            serviceUuid: service,
            entity: entity,
            specYaml: gerbingYaml,
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(widget);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    // 100 * 0.5 + 85 = 135.
    expect(find.text('135.0'), findsOneWidget);
    expect(find.text('50.0'), findsNothing, reason: 'the offset was dropped');
    expect(find.text('100'), findsNothing, reason: 'the raw count leaked');
    expect(find.text('°F'), findsOneWidget);
  });
}
