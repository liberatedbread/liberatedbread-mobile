// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/setpoint_control_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _stateChar = '90759319-1668-44da-9ef3-492d593bd1e5';

EntityActionDto _setValue({String? command}) => EntityActionDto(
      role: 'set_value',
      serviceUuid: '0313fb4e-198b-4f64-a883-52b218c10ccc',
      characteristicUuid: _stateChar,
      commandName: command,
      userParams: const [],
    );

/// Gerbing's resolved shape: a 0-100% heat channel written directly, read
/// back through the same characteristic.
EntityDto _heatEntity({bool writable = true}) => EntityDto(
      name: 'Heat Level 1',
      platform: 'number',
      unit: '%',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'heat_percent',
      onWhenNonzero: false,
      actions: writable ? [_setValue()] : const [],
      setpointMin: 0,
      setpointMax: 100,
      setpointStep: 1,
    );

Widget _wrap(
  EntityDto entity, {
  required FakeSpecCodec codec,
  required FakeBleService ble,
  String? stateServiceUuid = 's',
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SetpointControlCard(
              deviceId: 'd',
              stateServiceUuid: stateServiceUuid,
              entity: entity,
              specYaml: 'y',
            ),
          ),
        ),
      ),
    );

FakeSpecCodec _codecReading(
  int raw, {
  double? scale,
  double? valueOffset,
  String? unit,
  String? unitSource,
}) =>
    FakeSpecCodec(
      decoded: [
        DecodedValueDto(
          name: 'heat_percent',
          valueType: 'uint',
          display: '$raw',
          uintValue: raw,
          scale: scale,
          valueOffset: valueOffset,
          unit: unit,
          unitSource: unitSource,
        ),
      ],
      entityWrite: EntityWriteDto(
        serviceUuid: 's',
        characteristicUuid: _stateChar,
        bytes: Uint8List.fromList([60]),
      ),
    );

void main() {
  testWidgets('shows the live reading and a slider bounded by the spec',
      (tester) async {
    final codec = _codecReading(40);
    await tester.pumpWidget(
      _wrap(_heatEntity(), codec: codec, ble: FakeBleService()),
    );
    await tester.pumpAndSettle();

    expect(find.text('40'), findsOneWidget);
    expect(find.text('%'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0);
    expect(slider.max, 100);
    expect(slider.value, 40, reason: 'the control opens where the device is');
    expect(slider.divisions, 100, reason: 'step 1 over a 0-100 range');
  });

  testWidgets('sends the chosen value in decoded units on release',
      (tester) async {
    final codec = _codecReading(40);
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(_heatEntity(), codec: codec, ble: ble));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(codec.encodeEntityValueCalls, hasLength(1));
    final call = codec.encodeEntityValueCalls.single;
    expect(call.entityName, 'Heat Level 1');
    // Dragged to the far end of a 0-100 slider.
    expect(call.value, 100);
    // The codec decides the bytes AND the target; the card just writes them.
    expect(ble.writes.single.charUuid, _stateChar);
    expect(ble.writes.single.value, [60]);
  });

  testWidgets('dragging does not write until the gesture ends', (tester) async {
    // Each change is a BLE write; a per-frame send would flood the device.
    final codec = _codecReading(40);
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(_heatEntity(), codec: codec, ble: ble));
    await tester.pumpAndSettle();

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(codec.encodeEntityValueCalls, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(codec.encodeEntityValueCalls, hasLength(1));
  });

  testWidgets('applies scale and offset to the displayed reading',
      (tester) async {
    // Gerbing's thermometer: value = raw * 0.5 + 85 °F. Raw 100 is 135 °F,
    // and dropping the offset would read 50.
    const entity = EntityDto(
      name: 'Temperature Channel 1',
      platform: 'number',
      deviceClass: 'temperature',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'heat_percent',
      onWhenNonzero: false,
      actions: [],
    );
    await tester.pumpWidget(
      _wrap(
        entity,
        codec: _codecReading(100, scale: 0.5, valueOffset: 85, unit: '°F'),
        ble: FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('135'), findsOneWidget);
    expect(find.text('50'), findsNothing);
    expect(find.text('100'), findsNothing);
  });

  testWidgets('a read-only setpoint states its range instead of a control',
      (tester) async {
    // Ember's target temperature: its bytes cannot be encoded yet, but the
    // declared 49-63 °C range is still worth telling the user.
    const entity = EntityDto(
      name: 'Target Temperature',
      platform: 'number',
      deviceClass: 'temperature',
      unit: 'C',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'heat_percent',
      valueScale: 0.01,
      onWhenNonzero: false,
      actions: [],
      setpointMin: 49,
      setpointMax: 63,
    );
    await tester.pumpWidget(
      _wrap(entity, codec: _codecReading(5500), ble: FakeBleService()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsNothing);
    // 5500 centidegrees, shown to the 0.5 resolution a 49-63 range implies.
    expect(find.text('55.0'), findsOneWidget);
    expect(find.textContaining('does not describe how to set it yet'),
        findsOneWidget);
    expect(find.textContaining('49'), findsOneWidget);
  });

  testWidgets('a write-only setpoint says the current value is unknown',
      (tester) async {
    final entity = EntityDto(
      name: 'Heat Level 1',
      platform: 'number',
      unit: '%',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [_setValue()],
      setpointMin: 0,
      setpointMax: 100,
      setpointStep: 1,
    );
    final codec = _codecReading(0);
    await tester.pumpWidget(
      _wrap(entity,
          codec: codec, ble: FakeBleService(), stateServiceUuid: null),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current value unknown'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget,
        reason: 'not knowing the state does not stop us setting it');
  });

  testWidgets('marks a unit that follows a device setting', (tester) async {
    // The Inkbird iBBQ sends raw numbers in whichever unit it is set to, so
    // the reading must not present its unit as fact.
    await tester.pumpWidget(
      _wrap(
        _heatEntity(writable: false),
        codec: _codecReading(165, unit: 'C', unitSource: 'device_setting'),
        ble: FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('The device decides this unit; it is not fixed by the '
          'protocol.'),
      findsOneWidget,
    );
  });

  testWidgets('a rejected value surfaces instead of looking applied',
      (tester) async {
    final codec = FakeSpecCodec(
      decoded: const [
        DecodedValueDto(
          name: 'heat_percent',
          valueType: 'uint',
          display: '40',
          uintValue: 40,
        ),
      ],
      encodeEntityValueError: StateError('out of range'),
    );
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(_heatEntity(), codec: codec, ble: ble));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(ble.writes, isEmpty,
        reason: 'nothing is written when encoding fails');
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('without a declared range the control offers steppers',
      (tester) async {
    // No min/max means a slider would be inventing bounds.
    final entity = EntityDto(
      name: 'Animation Speed',
      platform: 'number',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [_setValue(command: 'set_speed')],
    );
    final codec = _codecReading(0);
    final ble = FakeBleService();
    await tester.pumpWidget(
      _wrap(entity, codec: codec, ble: ble, stateServiceUuid: null),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(codec.encodeEntityValueCalls, isEmpty,
        reason: 'nudging stages a value; Set sends it');

    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(codec.encodeEntityValueCalls, hasLength(1));
    expect(ble.writes, hasLength(1));
  });
}
