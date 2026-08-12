// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/entity_sensor_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _tempChar = 'fc540002-236c-4c94-8fa9-944a3e5353fa';

/// A spec-declared temperature reading in centidegrees, as Ember's mug reports
/// it: raw 5320 with `scale: 0.01` means 53.20 °C.
EntityDto _tempEntity(
        {double? scale, String? valueField, bool canNotify = false}) =>
    EntityDto(
      name: 'Current Temperature',
      platform: 'sensor',
      deviceClass: 'temperature',
      unit: 'C',
      stateCharacteristic: _tempChar,
      canNotify: canNotify,
      hasFormat: true,
      valueField: valueField ?? 'current_temp_raw',
      valueScale: scale,
      onWhenNonzero: false,
      actions: const [],
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

  testWidgets(
      'a spec that never subscribes still reads a notify-only '
      'characteristic', (tester) async {
    // Spec/hardware drift: the entity says canNotify=false (so no
    // subscription will ever exist) while discovery reports the
    // characteristic notify-only. Skipping the seed here would leave a
    // spinner forever — the read must still be attempted, succeed or fail.
    final ble = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(uuid: 's', characteristics: [
          BleDiscoveredCharacteristic(
            uuid: _tempChar,
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ]),
      ],
      readValues: const {
        _tempChar: [87],
      },
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(_codecReturning(87)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntitySensorCard(
            deviceId: 'd',
            serviceUuid: 's',
            entity: _tempEntity(), // canNotify: false
            specYaml: 'y',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('87'), findsOneWidget);
  });

  testWidgets(
      'a failed subscription surfaces an error instead of an eternal '
      'spinner', (tester) async {
    // With the seed read skipped (notify-only), a CCCD write the peripheral
    // refuses is the card's only signal. Before any value has arrived it
    // must land as an error; the old handler swallowed it.
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final ble = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(uuid: 's', characteristics: [
          BleDiscoveredCharacteristic(
            uuid: _tempChar,
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ]),
      ],
      readError: Exception('reads refused'),
      notifyStream: notify.stream,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(_codecReturning(87)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntitySensorCard(
            deviceId: 'd',
            serviceUuid: 's',
            entity: _tempEntity(canNotify: true),
            specYaml: 'y',
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    notify.addError(Exception('CCCD write refused'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Could not read'), findsOneWidget);
  });

  testWidgets(
      'a notify-only characteristic waits for its first notification '
      'instead of wearing a read error', (tester) async {
    // Discovery says the characteristic cannot be read; the old behavior
    // issued the read anyway and showed its failure until the first
    // notification arrived. readError proves no read is attempted now.
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final ble = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(uuid: 's', characteristics: [
          BleDiscoveredCharacteristic(
            uuid: _tempChar,
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ]),
      ],
      readError: Exception('reads refused'),
      notifyStream: notify.stream,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(_codecReturning(87)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EntitySensorCard(
            deviceId: 'd',
            serviceUuid: 's',
            entity: _tempEntity(canNotify: true),
            specYaml: 'y',
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Could not read'), findsNothing);

    notify.add(const [87]);
    await tester.pump();
    await tester.pump();
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
      onWhenNonzero: false,
      actions: [],
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
      onWhenNonzero: false,
      actions: [],
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

  group('verdict chips', () {
    EntityDto entity({String? deviceClass, String? unit}) => EntityDto(
          name: 'Reading',
          platform: 'sensor',
          deviceClass: deviceClass,
          unit: unit,
          stateCharacteristic: _tempChar,
          canNotify: false,
          hasFormat: true,
          valueField: 'current_temp_raw',
          onWhenNonzero: false,
          actions: const [],
        );

    testWidgets('a radon reading past the red line says Poor', (tester) async {
      // 180 Bq/m³ is past Airthings' own red default (150) and the number
      // alone tells nobody that. The verdict is the point of the card.
      await tester.pumpWidget(_wrap(
        entity(unit: 'Bq/m³'),
        _codecReturning(180),
      ));
      await tester.pumpAndSettle();

      expect(find.text('180'), findsOneWidget);
      expect(find.text('Poor'), findsOneWidget);
    });

    testWidgets('a CO₂ reading between the bands says Fair', (tester) async {
      await tester.pumpWidget(_wrap(
        entity(deviceClass: 'carbon_dioxide', unit: 'ppm'),
        _codecReturning(900),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Fair'), findsOneWidget);
    });

    testWidgets('a healthy air reading says Good out loud', (tester) async {
      await tester.pumpWidget(_wrap(
        entity(deviceClass: 'humidity', unit: '%'),
        _codecReturning(45),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Good'), findsOneWidget);
    });

    testWidgets('the verdict judges the DECODED value, not the raw count',
        (tester) async {
      // A humidity field encoded at 0.01 %/count: raw 4500 is 45 % — Good.
      // Banding the raw count would read 4500 % as catastrophic.
      await tester.pumpWidget(_wrap(
        entity(deviceClass: 'humidity', unit: '%'),
        _codecReturning(4500, scale: 0.01),
      ));
      await tester.pumpAndSettle();

      expect(find.text('45.00'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('Poor'), findsNothing);
    });

    testWidgets('a healthy battery keeps quiet; a low one warns',
        (tester) async {
      await tester.pumpWidget(_wrap(
        entity(deviceClass: 'battery', unit: '%'),
        _codecReturning(85),
      ));
      await tester.pumpAndSettle();
      expect(find.text('85'), findsOneWidget);
      expect(find.text('Good'), findsNothing);

      // Torn down between scenarios: the value builder reads once at mount,
      // so an in-place re-pump would keep showing the first codec's value.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_wrap(
        entity(deviceClass: 'battery', unit: '%'),
        _codecReturning(15),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Fair'), findsOneWidget);
    });

    testWidgets('unbanded quantities show the number alone', (tester) async {
      await tester.pumpWidget(
        _wrap(_tempEntity(scale: 0.01), _codecReturning(5320)),
      );
      await tester.pumpAndSettle();

      expect(find.text('53.20'), findsOneWidget);
      for (final verdict in ['Good', 'Fair', 'Poor']) {
        expect(find.text(verdict), findsNothing);
      }
    });
  });

  group('compact tile', () {
    testWidgets('carries the same reading, unit and verdict as the row',
        (tester) async {
      const entity = EntityDto(
        name: 'Radon 24h Average',
        platform: 'sensor',
        deviceClass: null,
        unit: 'Bq/m³',
        stateCharacteristic: _tempChar,
        canNotify: true,
        hasFormat: true,
        valueField: 'current_temp_raw',
        onWhenNonzero: false,
        actions: [],
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(
            FakeBleService(readValues: const {
              _tempChar: [55, 0],
            }),
          ),
          specCodecProvider.overrideWithValue(_codecReturning(55)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: EntitySensorCard(
              deviceId: 'd',
              serviceUuid: 's',
              entity: entity,
              specYaml: 'y',
              compact: true,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Radon 24h Average'), findsOneWidget);
      expect(find.text('55'), findsOneWidget);
      expect(find.text('Bq/m³'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      // The live-updates affordance survives the compact layout.
      expect(find.byIcon(Icons.bolt), findsOneWidget);
    });
  });
}
