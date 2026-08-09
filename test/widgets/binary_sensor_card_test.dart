// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/binary_sensor_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _stateChar = 'fc540007-236c-4c94-8fa9-944a3e5353fa';

/// Ember's charging-base shape: a status byte where exactly `on_value` means
/// docked.
EntityDto _chargingEntity({int? onValue = 1, String? deviceClass}) => EntityDto(
      name: 'Charging Base',
      platform: 'binary_sensor',
      deviceClass: deviceClass,
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'on_charging_base',
      onValue: onValue,
      onWhenNonzero: false,
      actions: const [],
    );

Widget _wrap(EntityDto entity, FakeSpecCodec codec) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(
          FakeBleService(readValues: const {
            _stateChar: [1],
          }),
        ),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: BinarySensorCard(
            deviceId: 'd',
            serviceUuid: 's',
            entity: entity,
            specYaml: 'y',
          ),
        ),
      ),
    );

FakeSpecCodec _codecReturning(int raw) => FakeSpecCodec(decoded: [
      DecodedValueDto(
        name: 'on_charging_base',
        valueType: 'uint',
        display: '$raw',
        uintValue: raw,
      ),
    ]);

void main() {
  testWidgets('reads On when the value matches on_value', (tester) async {
    await tester.pumpWidget(_wrap(_chargingEntity(), _codecReturning(1)));
    await tester.pumpAndSettle();

    expect(find.text('On'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
  });

  testWidgets('reads Off when the value misses on_value', (tester) async {
    // A nonzero non-matching value must NOT read as on: `on_value: 1` means
    // exactly 1, and e.g. an error status of 2 is not "docked".
    await tester.pumpWidget(_wrap(_chargingEntity(), _codecReturning(2)));
    await tester.pumpAndSettle();

    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('without on_value any nonzero value reads On', (tester) async {
    await tester
        .pumpWidget(_wrap(_chargingEntity(onValue: null), _codecReturning(2)));
    await tester.pumpAndSettle();

    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('a bool field speaks for itself', (tester) async {
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
        name: 'on_charging_base',
        valueType: 'bool',
        display: 'on',
        boolValue: true,
      ),
    ]);
    await tester.pumpWidget(_wrap(_chargingEntity(onValue: null), codec));
    await tester.pumpAndSettle();

    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('problem device_class words the states as Problem/OK',
      (tester) async {
    await tester.pumpWidget(
      _wrap(_chargingEntity(deviceClass: 'problem'), _codecReturning(0)),
    );
    await tester.pumpAndSettle();

    expect(find.text('OK'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
  });

  testWidgets('reports a missing format block instead of a blank state',
      (tester) async {
    const entity = EntityDto(
      name: 'Lid',
      platform: 'binary_sensor',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [],
    );
    await tester.pumpWidget(_wrap(entity, _codecReturning(0)));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot be decoded'), findsOneWidget);
  });
}
