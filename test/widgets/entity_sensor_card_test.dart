// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/entity_sensor_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _tempChar = 'fc540002-236c-4c94-8fa9-944a3e5353fa';

/// A spec-declared temperature reading in centidegrees, as Ember's mug reports
/// it: raw 5320 with `scale: 0.01` means 53.20 °C.
EntityDto _tempEntity({double? scale, String? valueField}) => EntityDto(
      name: 'Current Temperature',
      platform: 'sensor',
      deviceClass: 'temperature',
      unit: 'C',
      stateCharacteristic: _tempChar,
      canNotify: false,
      hasFormat: true,
      valueField: valueField ?? 'current_temp_raw',
      valueScale: scale,
    );

Widget _wrap(EntityDto entity, FakeSpecCodec codec) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(
          FakeBleService(readValues: const {
            _tempChar: [200, 20],
          }),
        ),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntitySensorCard(
            deviceId: 'd',
            serviceUuid: 's',
            entity: entity,
            specYaml: 'y',
          ),
        ),
      ),
    );

FakeSpecCodec _codecReturning(int raw, {double? scale, String? unit}) =>
    FakeSpecCodec(decoded: [
      DecodedValueDto(
        name: 'current_temp_raw',
        valueType: 'uint',
        display: '$raw',
        uintValue: raw,
        scale: scale,
        unit: unit,
      ),
    ]);

void main() {
  testWidgets('applies the spec-declared scale to the raw reading',
      (tester) async {
    await tester.pumpWidget(
      _wrap(_tempEntity(scale: 0.01), _codecReturning(5320)),
    );
    await tester.pumpAndSettle();

    // 5320 centidegrees is 53.20 °C. Showing the raw value would be wrong by
    // two orders of magnitude, which is the whole reason scale lives in the
    // spec.
    expect(find.text('53.20'), findsOneWidget);
    expect(find.text('5320'), findsNothing);
    expect(find.text('C'), findsOneWidget);
  });

  testWidgets('shows the decoder display string when no scale is declared',
      (tester) async {
    await tester.pumpWidget(_wrap(_tempEntity(), _codecReturning(87)));
    await tester.pumpAndSettle();

    expect(find.text('87'), findsOneWidget);
  });

  testWidgets('reports a missing format block instead of a blank reading',
      (tester) async {
    // An entity can name a characteristic whose byte layout the spec never
    // describes. That is a spec gap, and saying so is more useful than an
    // empty tile that looks broken.
    const entity = EntityDto(
      name: 'Probe Temperature',
      platform: 'sensor',
      deviceClass: 'temperature',
      unit: 'F',
      stateCharacteristic: _tempChar,
      canNotify: true,
      hasFormat: false,
      valueField: null,
      valueScale: null,
    );

    await tester.pumpWidget(_wrap(entity, _codecReturning(0)));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot be decoded'), findsOneWidget);
  });

  testWidgets('applies a scale declared on the format field', (tester) async {
    // Airthings and Miflora put `scale` on the format field rather than on the
    // entity — the Bluetooth SIG temperature characteristic is int16 in
    // hundredths of a degree. Ignoring it renders 2350 for a 23.5 °C room.
    await tester.pumpWidget(
      _wrap(
        _tempEntity(),
        _codecReturning(2350, scale: 0.01),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('23.50'), findsOneWidget);
    expect(find.text('2350'), findsNothing);
  });

  testWidgets('entity scale wins over the format field scale', (tester) async {
    // Both levels can declare a scale. The entity is the more specific of the
    // two — it describes this particular reading rather than the field's
    // encoding — so it must win, and the two must never compound.
    await tester.pumpWidget(
      _wrap(
        _tempEntity(scale: 0.01),
        _codecReturning(5320, scale: 0.1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('53.20'), findsOneWidget);
    expect(find.text('532.0'), findsNothing);
  });

  testWidgets('falls back to the format field unit when the entity has none',
      (tester) async {
    const entity = EntityDto(
      name: 'Temperature',
      platform: 'sensor',
      deviceClass: 'temperature',
      unit: null,
      stateCharacteristic: _tempChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'current_temp_raw',
      valueScale: null,
    );

    await tester.pumpWidget(
      _wrap(entity, _codecReturning(2350, scale: 0.01, unit: '°C')),
    );
    await tester.pumpAndSettle();

    expect(find.text('23.50'), findsOneWidget);
    expect(find.text('°C'), findsOneWidget);
  });

  testWidgets('reports when the mapped field is absent from the format',
      (tester) async {
    // The spec maps the reading to a field its own format block never defines:
    // surfacing the mismatch beats rendering an unrelated field's value.
    await tester.pumpWidget(
      _wrap(_tempEntity(valueField: 'not_in_format'), _codecReturning(5320)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('not_in_format'), findsOneWidget);
  });
}
