// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The BLE card for the platforms the unified role table added: a button
// presses its bound command, a select's chips send the option's RAW value
// through the role's parameter, and a cover renders its three motions.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/entity_cards/ble_entity_action_card.dart';

import '../../fakes/fake_ble_service.dart';
import '../../fakes/fake_spec_codec.dart';

const _cmdChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const _cmdService = '0000fff0-0000-1000-8000-00805f9b34fb';
const _stateChar = '0000fff2-0000-1000-8000-00805f9b34fb';

EntityActionDto _action(
  String role,
  String command, {
  List<String> userParams = const [],
  double? min,
  double? max,
}) => EntityActionDto(
  role: role,
  serviceUuid: _cmdService,
  characteristicUuid: _cmdChar,
  commandName: command,
  userParams: userParams,
  min: min,
  max: max,
);

Widget _wrap(
  EntityDto entity, {
  required FakeSpecCodec codec,
  required FakeBleService ble,
  String? stateServiceUuid,
}) => ProviderScope(
  overrides: [
    bleServiceProvider.overrideWithValue(ble),
    specCodecProvider.overrideWithValue(codec),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: BleEntityActionCard(
        deviceId: 'd',
        stateServiceUuid: stateServiceUuid,
        entity: entity,
        specYaml: 'y',
      ),
    ),
  ),
);

void main() {
  testWidgets('a button presses its bound command', (tester) async {
    final entity = EntityDto(
      options: const [],
      name: 'Start',
      platform: 'button',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [_action('press', 'start_belt')],
      variants: const [],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xA2]));
    final ble = FakeBleService();

    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    // Momentary: no claimed state, one press control.
    expect(find.text('Momentary'), findsOneWidget);
    await tester.tap(find.text('Press'));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'start_belt');
    expect(codec.encodeCalls.single.params, isEmpty);
    expect(ble.writes.single.value, [0xF7, 0xA2]);
  });

  testWidgets('a select chip sends the option raw through the role parameter', (
    tester,
  ) async {
    final entity = EntityDto(
      options: const [
        NetworkOptionDto(raw: '0', label: 'Automatic'),
        NetworkOptionDto(raw: '1', label: 'Manual'),
        NetworkOptionDto(raw: '2', label: 'Standby'),
      ],
      name: 'Belt Mode',
      platform: 'select',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _action('select_option', 'switch_mode', userParams: ['mode']),
      ],
      variants: const [],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x01]));
    final ble = FakeBleService();

    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'Manual'));
    await tester.pumpAndSettle();

    final call = codec.encodeCalls.single;
    expect(call.commandName, 'switch_mode');
    // The RAW value rides the role's own parameter — the label and the chip
    // index must never be what goes on the wire.
    expect(call.params, {'mode': 1.0});
    // The sent option shows as selected until a fresh decode says otherwise.
    final manual = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Manual'),
    );
    expect(manual.selected, isTrue);
  });

  testWidgets('a fan slider follows the finger while the state is live', (
    tester,
  ) async {
    // Regression. With a bound state characteristic the card is rebuilt under
    // EntityValueBuilder, and every rebuild used to clear the in-drag value
    // because it was kept in the same slot as the "assumed after send" value
    // — whose baseline is only recorded at release. So the thumb sat pinned
    // at the device's reported speed for the whole gesture and only the
    // release value went out: a control that looked broken while it was
    // being used.
    final entity = EntityDto(
      options: const [],
      name: 'Circulation',
      platform: 'fan',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      onWhenNonzero: false,
      actions: [
        _action(
          'set_percentage',
          'set_speed',
          userParams: const ['speed'],
          min: 0,
          max: 100,
        ),
      ],
      variants: const [],
    );
    final codec = FakeSpecCodec(
      encoded: Uint8List.fromList([0x28]),
      decoded: const [
        DecodedValueDto(
          name: 'speed',
          valueType: 'uint',
          display: '40',
          uintValue: 40,
        ),
      ],
    );
    final ble = FakeBleService(
      readValues: const {
        _stateChar: [40],
      },
    );

    await tester.pumpWidget(
      _wrap(entity, codec: codec, ble: ble, stateServiceUuid: 's'),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      40,
      reason: 'seeded from the live decode',
    );

    // Press on the track past the thumb and keep the finger down: the slider
    // reports the new position through onChanged before anything is sent.
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    final held = tester.widget<Slider>(slider).value;
    expect(
      held,
      greaterThan(40),
      reason:
          'the thumb must track the drag, not snap back to the '
          'device value on every rebuild',
    );
    expect(
      ble.writes,
      isEmpty,
      reason: 'nothing goes out until the finger lifts',
    );

    await gesture.up();
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'set_speed');
    expect(codec.encodeCalls.single.params, {'speed': held.roundToDouble()});
    expect(ble.writes, hasLength(1));
    // And the sent value stays on the slider until a fresh decode says
    // otherwise, rather than reverting to the pre-drag reading.
    expect(tester.widget<Slider>(slider).value, held);
  });

  testWidgets('a cover renders its motions and sends open', (tester) async {
    final entity = EntityDto(
      options: const [],
      name: 'Print Feed',
      platform: 'cover',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _action('open_cover', 'feed_open'),
        _action('close_cover', 'feed_close'),
        _action('stop_cover', 'feed_stop'),
      ],
      variants: const [],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xAA]));
    final ble = FakeBleService();

    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    // No live position: the slider that would claim to show one is absent.
    expect(find.byType(Slider), findsNothing);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls.single.commandName, 'feed_open');
  });
}
