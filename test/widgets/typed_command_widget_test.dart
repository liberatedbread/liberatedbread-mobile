// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/typed_command_widget.dart';

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
      isEncodable: true,
      unsupportedEncoding: null,
    ),
    CommandDto(
      name: 'set_brightness',
      description: 'Set brightness',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      parameters: [
        ParameterDto(name: 'brightness', valueType: 'uint8', min: 0, max: 100),
      ],
    ),
  ],
  formatFields: [],
);

// A malformed spec — as might arrive from an untrusted remote pack — with an
// inverted parameter range (min > max) that would otherwise crash the Slider.
const _malformedChar = CharacteristicDto(
  uuid: _char,
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'set_level',
      description: 'Broken range',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      parameters: [
        ParameterDto(name: 'level', valueType: 'uint8', min: 200, max: 50),
      ],
    ),
  ],
  formatFields: [],
);

Widget _wrap({
  required FakeBleService ble,
  required FakeSpecCodec codec,
  CharacteristicDto specChar = _charDto,
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TypedCommandWidget(
              deviceId: 'd',
              serviceUuid: _svc,
              specYaml: 'yaml',
              specChar: specChar,
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

  testWidgets('renders a valid Slider for a malformed inverted range',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([3, 0]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _malformedChar));

    // No assertion/throw during build, and the slider gets a well-ordered range.
    expect(tester.takeException(), isNull);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min < slider.max, isTrue);
    expect(slider.value, inInclusiveRange(slider.min, slider.max));
  });

  testWidgets('surfaces an error when encoding fails', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encodeError: StateError('bad param'));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.widgetWithText(ElevatedButton, 'Power on'));
    await tester.pumpAndSettle();

    expect(find.textContaining('did not accept that command'), findsWidgets);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('bad param'), findsNothing);
    expect(ble.writes, isEmpty);
  });
}
