// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/switch_control_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _cmdChar = '00010203-0405-0607-0809-0a0b0c0d2b11';
const _cmdService = '00010203-0405-0607-0809-0a0b0c0d1910';
const _stateChar = 'fc540003-236c-4c94-8fa9-944a3e5353fa';

EntityActionDto _fixedAction(String role, String command) => EntityActionDto(
      role: role,
      serviceUuid: _cmdService,
      characteristicUuid: _cmdChar,
      commandName: command,
      userParams: const [],
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
          body: SwitchControlCard(
            deviceId: 'd',
            stateServiceUuid: stateServiceUuid,
            entity: entity,
            specYaml: 'y',
          ),
        ),
      ),
    );

void main() {
  testWidgets(
      'a stateless switch renders On/Off buttons and sends the bound command',
      (tester) async {
    // govee's plug: commands only, no state characteristic at all. A toggle
    // would claim to know the current state; buttons promise nothing.
    final entity = EntityDto(
      name: 'Plug Outlet',
      platform: 'switch',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _fixedAction('turn_on', 'turn_on'),
        _fixedAction('turn_off', 'turn_off'),
      ],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x33, 0x01]));
    final ble = FakeBleService();

    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNothing);
    expect(find.text('State unknown — commands send blind'), findsOneWidget);

    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls, hasLength(1));
    expect(codec.encodeCalls.single.commandName, 'turn_on');
    expect(codec.encodeCalls.single.charUuid, _cmdChar);
    expect(ble.writes, hasLength(1));
    expect(ble.writes.single.charUuid, _cmdChar);
    expect(ble.writes.single.value, [0x33, 0x01]);
  });

  testWidgets('a switch with readable state renders a toggle that sends',
      (tester) async {
    final entity = EntityDto(
      name: 'Temperature Control',
      platform: 'switch',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'target_temp_raw',
      onWhenNonzero: true,
      actions: [
        _fixedAction('turn_on', 'enable'),
        _fixedAction('turn_off', 'disable'),
      ],
    );
    // Device reports a nonzero target temperature: on.
    final codec = FakeSpecCodec(
      decoded: const [
        DecodedValueDto(
          name: 'target_temp_raw',
          valueType: 'uint',
          display: '5320',
          uintValue: 5320,
        ),
      ],
      encoded: Uint8List.fromList([0x00]),
    );
    final ble = FakeBleService(readValues: const {
      _stateChar: [0xC8, 0x14],
    });

    await tester.pumpWidget(
      _wrap(entity, codec: codec, ble: ble, stateServiceUuid: 's'),
    );
    await tester.pumpAndSettle();

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isTrue, reason: 'nonzero reading means on');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'disable',
        reason: 'toggling an on switch sends turn_off');
    expect(ble.writes, hasLength(1));
    expect(find.text('Off (sent)'), findsOneWidget);
  });

  testWidgets('a press action renders a momentary button', (tester) async {
    // SwitchBot's bot: press alongside on/off. All three must be sendable.
    final entity = EntityDto(
      name: 'Bot Press',
      platform: 'switch',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _fixedAction('turn_on', 'bot_turn_on'),
        _fixedAction('turn_off', 'bot_turn_off'),
        _fixedAction('press', 'bot_press'),
      ],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x57, 0x01]));
    final ble = FakeBleService();

    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    // Without readable state everything renders as buttons: assumed-state
    // On/Off, and the momentary Press alongside them.
    expect(find.byType(Switch), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'On'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Off'), findsOneWidget);
    await tester.tap(find.text('Press'));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'bot_press');
    expect(ble.writes, hasLength(1));
  });

  testWidgets('a switch with state but no sendable actions is read-only',
      (tester) async {
    // ember's temperature-control switch binds prose, not commands: live
    // state with no way to change it is exactly what the spec supports.
    final entity = EntityDto(
      name: 'Temperature Control',
      platform: 'switch',
      stateCharacteristic: _stateChar,
      canNotify: false,
      hasFormat: true,
      valueField: 'target_temp_raw',
      onWhenNonzero: true,
      actions: const [],
    );
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
        name: 'target_temp_raw',
        valueType: 'uint',
        display: '0',
        uintValue: 0,
      ),
    ]);
    final ble = FakeBleService(readValues: const {
      _stateChar: [0, 0],
    });

    await tester.pumpWidget(
      _wrap(entity, codec: codec, ble: ble, stateServiceUuid: 's'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('an encode failure surfaces instead of pretending success',
      (tester) async {
    final entity = EntityDto(
      name: 'Plug Outlet',
      platform: 'switch',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _fixedAction('turn_on', 'turn_on'),
        _fixedAction('turn_off', 'turn_off'),
      ],
    );
    final codec = FakeSpecCodec(encodeError: StateError('bad param'));
    final ble = FakeBleService();

    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();

    expect(ble.writes, isEmpty, reason: 'nothing must be written on failure');
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
