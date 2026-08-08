// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/light_control_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _cmdChar = '0000fff3-0000-1000-8000-00805f9b34fb';
const _cmdService = '0000fff0-0000-1000-8000-00805f9b34fb';
const _stateChar = '0000fff2-0000-1000-8000-00805f9b34fb';

EntityActionDto _action(
  String role,
  String command, {
  List<String> userParams = const [],
  double? min,
  double? max,
}) =>
    EntityActionDto(
      role: role,
      serviceUuid: _cmdService,
      characteristicUuid: _cmdChar,
      commandName: command,
      userParams: userParams,
      min: min,
      max: max,
    );

/// elk-bledom's resolved shape: brightness (bounded 0..100) and color, no
/// power.
EntityDto _stripEntity() => EntityDto(
      name: 'LED Strip',
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _action('set_brightness', 'set_brightness',
            userParams: const ['brightness'], min: 0, max: 100),
        _action('set_color', 'set_rgb_color',
            userParams: const ['red', 'green', 'blue']),
      ],
    );

Widget _wrap(
  EntityDto entity, {
  required FakeSpecCodec codec,
  required FakeBleService ble,
  String? stateServiceUuid,
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LightControlCard(
              deviceId: 'd',
              stateServiceUuid: stateServiceUuid,
              entity: entity,
              specYaml: 'y',
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('renders only the controls whose roles resolved',
      (tester) async {
    final codec = FakeSpecCodec();
    await tester
        .pumpWidget(_wrap(_stripEntity(), codec: codec, ble: FakeBleService()));
    await tester.pumpAndSettle();

    // No power action resolved (elk's on/off byte is ambiguous), so no
    // toggle and no On/Off buttons — but brightness and color are live.
    expect(find.byType(Switch), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'On'), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('tapping a swatch sends the color command with RGB params',
      (tester) async {
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([1, 2, 3]));
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(_stripEntity(), codec: codec, ble: ble));
    await tester.pumpAndSettle();

    // The third swatch is pure red (after white and warm white).
    final swatches = find.byWidgetPredicate(
      (w) => w is InkWell && w.borderRadius == BorderRadius.circular(19),
    );
    await tester.tap(swatches.at(2));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls, hasLength(1));
    final call = codec.encodeCalls.single;
    expect(call.commandName, 'set_rgb_color');
    expect(call.params['red'], 255.0);
    expect(call.params['green'], 0.0);
    expect(call.params['blue'], 0.0);
    expect(ble.writes.single.value, [1, 2, 3]);
  });

  testWidgets('the brightness slider honors the spec bounds and sends on '
      'release', (tester) async {
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([9]));
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(_stripEntity(), codec: codec, ble: ble));
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, 100, reason: 'elk-bledom tops out at 100, not 255');

    await tester.drag(find.byType(Slider), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls, hasLength(1));
    final call = codec.encodeCalls.single;
    expect(call.commandName, 'set_brightness');
    expect(call.params.containsKey('brightness'), isTrue);
    expect(ble.writes, hasLength(1));
  });

  testWidgets(
      'brightness riding the color command stages until a color is known',
      (tester) async {
    // ember's LED: no dedicated brightness command; set_led_color carries
    // brightness. Committing the slider before any color is known must NOT
    // invent a color to send.
    final entity = EntityDto(
      name: 'LED',
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _action('set_color', 'set_led_color',
            userParams: const ['red', 'green', 'blue', 'brightness']),
      ],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0]));
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    expect(find.byType(Slider), findsOneWidget,
        reason: 'the color command carries brightness, so the slider shows');

    await tester.drag(find.byType(Slider), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls, isEmpty,
        reason: 'no color known yet — nothing safe to send');

    final swatches = find.byWidgetPredicate(
      (w) => w is InkWell && w.borderRadius == BorderRadius.circular(19),
    );
    await tester.tap(swatches.at(2));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls, hasLength(1));
    expect(codec.encodeCalls.single.params.containsKey('brightness'), isTrue);

    await tester.drag(find.byType(Slider), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls, hasLength(2),
        reason: 'with a color known, brightness commits re-send the color');
    expect(codec.encodeCalls.last.commandName, 'set_led_color');
  });

  testWidgets('power toggle sends and reports the assumed state',
      (tester) async {
    final entity = EntityDto(
      name: 'Bulb',
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _action('turn_on', 'power_on'),
        _action('turn_off', 'power_off'),
      ],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xCC]));
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'power_on');
    expect(find.text('On (sent)'), findsNothing,
        reason: 'without live state the status stays a plain Ready line');
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('seeds control positions from decoded device state',
      (tester) async {
    // example-bulb's shape: readable power/brightness/color. The card must
    // open showing what the device reports, not defaults.
    final entity = EntityDto(
      name: 'Bulb',
      platform: 'light',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      isOnField: 'power_state',
      brightnessField: 'brightness',
      colorRedField: 'red',
      colorGreenField: 'green',
      colorBlueField: 'blue',
      onWhenNonzero: false,
      actions: [
        _action('turn_on', 'power_on'),
        _action('turn_off', 'power_off'),
        _action('set_brightness', 'set_brightness',
            userParams: const ['brightness'], min: 0, max: 255),
        _action('set_color', 'set_color',
            userParams: const ['red', 'green', 'blue']),
      ],
    );
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
        name: 'power_state',
        valueType: 'bool',
        display: 'on',
        boolValue: true,
      ),
      DecodedValueDto(
        name: 'brightness',
        valueType: 'uint',
        display: '80',
        uintValue: 80,
      ),
      DecodedValueDto(
          name: 'red', valueType: 'uint', display: '255', uintValue: 255),
      DecodedValueDto(
          name: 'green', valueType: 'uint', display: '0', uintValue: 0),
      DecodedValueDto(
          name: 'blue', valueType: 'uint', display: '0', uintValue: 0),
    ]);
    final ble = FakeBleService(readValues: const {
      _stateChar: [1, 80, 255, 0, 0],
    });

    await tester.pumpWidget(
      _wrap(entity, codec: codec, ble: ble, stateServiceUuid: 's'),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 80);
    expect(find.text('On'), findsOneWidget);
  });
}
