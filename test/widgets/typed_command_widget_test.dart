// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/providers/spec_codec_provider.dart';
import 'package:opengreeniot_mobile/services/spec_codec.dart';
import 'package:opengreeniot_mobile/widgets/typed_command_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _char = '0000fff1-0000-1000-8000-00805f9b34fb';

const _charDto = CharacteristicDto(
  uuid: _char,
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'power_on',
      description: 'Turn the bulb on',
      parameters: [],
      isFixed: true,
    ),
    CommandDto(
      name: 'set_brightness',
      description: 'Set brightness',
      isFixed: false,
      parameters: [
        ParameterDto(name: 'brightness', valueType: 'uint8', min: 0, max: 100),
      ],
    ),
  ],
  formatFields: [],
);

Widget _wrap({required FakeBleService ble, required FakeSpecCodec codec}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TypedCommandWidget(
              deviceId: 'd',
              serviceUuid: _svc,
              specYaml: 'yaml',
              specChar: _charDto,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('fixed command encodes and writes, then shows Sent',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([1, 1]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.widgetWithText(ElevatedButton, 'Power on'));
    await tester.pumpAndSettle();

    expect(
        codec.encodeCalls.where((c) => c.commandName == 'power_on').length, 1);
    expect(ble.writes.single.value, [1, 1]);
    expect(find.text('Sent'), findsOneWidget);
  });

  testWidgets('parameterized command sends the rounded slider value',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([2, 64]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    // Move the slider to a fractional value; the UI rounds to an integer.
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(63.7);
    await tester.pump();
    expect(find.text('Brightness: 64'), findsOneWidget);

    // 'Send' is an ElevatedButton.icon (a private subtype), so tap its label.
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'set_brightness');
    expect(call.params['brightness'], 64.0);
    expect(ble.writes.single.value, [2, 64]);
  });

  testWidgets('surfaces an error when encoding fails', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encodeError: StateError('bad param'));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.widgetWithText(ElevatedButton, 'Power on'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Error:'), findsOneWidget);
    expect(ble.writes, isEmpty);
  });
}
