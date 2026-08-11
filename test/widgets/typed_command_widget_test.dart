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
      advanced: false,
    ),
    CommandDto(
      name: 'set_brightness',
      description: 'Set brightness',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(name: 'brightness', valueType: 'uint8', min: 0, max: 100),
      ],
    ),
  ],
  formatFields: [],
);

// A command whose parameter type has no numeric range; a slider would be a
// lie, so the widget must render an "unsupported" row instead.
const _stringParamChar = CharacteristicDto(
  uuid: _char,
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'set_label',
      description: 'Set the display label',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(name: 'label', valueType: 'string'),
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
      advanced: false,
      parameters: [
        ParameterDto(name: 'level', valueType: 'uint8', min: 200, max: 50),
      ],
    ),
  ],
  formatFields: [],
);

// A command mirroring admore's set_tail_brightness: the device accepts only
// an enumerated set of values with human labels, plus a second free-range
// parameter to prove sliders and dropdowns coexist within one command.
// Not const: `allowed` crosses the FFI as flutter_rust_bridge's Int64List.
final _allowedChar = CharacteristicDto(
  uuid: _char,
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'set_tail_brightness',
      description: 'Set tail light brightness',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(
          name: 'value',
          valueType: 'int32',
          allowed: Int64List.fromList([0, 200, 400, 1000]),
          labels: const ['OFF', 'Low', 'Mid', 'High'],
        ),
        const ParameterDto(name: 'speed', valueType: 'uint8', min: 0, max: 100),
      ],
    ),
  ],
  formatFields: [],
);

// Allowed values that arrive without usable labels: one parameter has no
// labels at all, the other has labels that cannot pair 1:1 with allowed
// (hand-built DTOs can bypass the Rust boundary that normally drops these).
// Both must render raw values rather than mispair or crash.
final _unlabeledAllowedChar = CharacteristicDto(
  uuid: _char,
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'set_level',
      description: 'No labels',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(
          name: 'level',
          valueType: 'uint16',
          allowed: Int64List.fromList([5, 10]),
        ),
      ],
    ),
    CommandDto(
      name: 'set_mode',
      description: 'Mispaired labels',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(
          name: 'mode',
          valueType: 'uint8',
          allowed: Int64List.fromList([7, 9]),
          labels: const ['Only'],
        ),
      ],
    ),
  ],
  formatFields: [],
);

// `allowed` on a bool is odd — a switch already enumerates both states, so
// the switch must win over the dropdown.
final _boolAllowedChar = CharacteristicDto(
  uuid: _char,
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'set_enabled',
      description: 'Bool with allowed',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(
          name: 'enabled',
          valueType: 'bool',
          allowed: Int64List.fromList([0, 1]),
          labels: const ['Off', 'On'],
        ),
      ],
    ),
  ],
  formatFields: [],
);

// Mirrors KingSmith's WiLink set_speed: a caller-owned speed parameter with
// presentation metadata (raw counts at 0.1 km/h), plus a checksum byte the
// encoder computes — which must get neither a control nor a seeded value.
const _scaledAutoChar = CharacteristicDto(
  uuid: _char,
  name: 'Command write',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'set_speed',
      description: 'Set belt speed',
      isFixed: false,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
      parameters: [
        ParameterDto(
          name: 'speed',
          valueType: 'uint8',
          min: 0,
          max: 60,
          scale: 0.1,
          unit: 'km/h',
        ),
        ParameterDto(name: 'checksum', valueType: 'uint8', auto: 'checksum'),
      ],
    ),
  ],
  formatFields: [],
);

// An ordinary command beside two advanced ones — one with the spec's own
// reason text, one without, so the dialog's fallback wording is exercised.
// KingSmith flags its calibration toggle advanced for exactly this reason.
const _advancedChar = CharacteristicDto(
  uuid: _char,
  name: 'Command write',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
      name: 'start_belt',
      description: 'Start the belt',
      parameters: [],
      isFixed: true,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
    ),
    CommandDto(
      name: 'calibration_mode',
      description: 'Calibration toggle',
      parameters: [],
      isFixed: true,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: true,
      advancedReason:
          'Calibration changes how command values map to real belt speed.',
    ),
    CommandDto(
      name: 'set_max_speed',
      description: 'Raise the speed ceiling',
      parameters: [],
      isFixed: true,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: true,
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

  testWidgets('string parameter gets an unsupported row, not a Slider',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _stringParamChar));

    expect(find.byType(Slider), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('Label: unsupported parameter type (string)'),
        findsOneWidget);
  });

  testWidgets(
      'allowed values render as a labeled dropdown, coexisting with a slider',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([1]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _allowedChar));

    // The enumerated parameter gets a dropdown defaulting to the first
    // allowed value; the free-range parameter keeps its slider.
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    expect(find.text('OFF (0)'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);

    // Opening the menu shows every allowed value with its label.
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    for (final entry in ['Low (200)', 'Mid (400)', 'High (1000)']) {
      expect(find.text(entry), findsOneWidget);
    }
    // Close the menu again to leave the tree settled.
    await tester.tap(find.text('Low (200)'));
    await tester.pumpAndSettle();
  });

  testWidgets('selecting an allowed entry sends its value, not label or index',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([9, 232, 3]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _allowedChar));

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High (1000)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final call = codec.encodeCalls
        .firstWhere((c) => c.commandName == 'set_tail_brightness');
    // The wire value is the allowed value itself — 1000 — never the label
    // ("High") or the dropdown index (3).
    expect(call.params['value'], 1000.0);
    // The untouched slider parameter still sends its default.
    expect(call.params['speed'], 0.0);
    expect(ble.writes.single.value, [9, 232, 3]);
    expect(find.text('Sent'), findsOneWidget);
  });

  testWidgets('allowed without usable labels falls back to raw values',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0]));
    await tester.pumpWidget(
        _wrap(ble: ble, codec: codec, specChar: _unlabeledAllowedChar));

    // Both enumerated parameters render dropdowns seeded with their first
    // allowed value, shown raw.
    expect(find.byType(DropdownButtonFormField<int>), findsNWidgets(2));
    expect(find.text('5'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);

    // The mispaired label must not attach to any value.
    await tester.tap(find.byType(DropdownButtonFormField<int>).last);
    await tester.pumpAndSettle();
    expect(find.text('9'), findsOneWidget);
    expect(find.textContaining('Only'), findsNothing);
    await tester.tap(find.text('9'));
    await tester.pumpAndSettle();
  });

  testWidgets('bool parameter keeps its switch even when allowed is declared',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _boolAllowedChar));

    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
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

  testWidgets(
      'an encoder-filled (auto) parameter gets no control and is '
      'never sent', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _scaledAutoChar));

    // One slider (speed), no checksum control anywhere: offering one would
    // let the user write over a byte the protocol computes.
    expect(find.byType(Slider), findsOneWidget);
    expect(find.textContaining('Checksum'), findsNothing);

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'set_speed');
    // Only the caller-owned parameter crosses the FFI; the encoder fills the
    // checksum itself.
    expect(call.params.containsKey('checksum'), isFalse);
    expect(call.params.keys, ['speed']);
  });

  testWidgets('a scaled parameter presents in decoded units and sends raw',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _scaledAutoChar));

    // Raw range 0..60 at scale 0.1 presents as 0.0..6.0 km/h, seeded at the
    // bottom of the range.
    expect(find.text('Speed: 0.0 km/h'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, closeTo(0.0, 1e-9));
    expect(slider.max, closeTo(6.0, 1e-9));

    // The slider works in display space; 3.0 km/h is raw 30 on the wire.
    slider.onChanged!(3.0);
    await tester.pump();
    expect(find.text('Speed: 3.0 km/h'), findsOneWidget);

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'set_speed');
    expect(call.params['speed'], 30.0);
  });

  testWidgets('advanced commands stay collapsed until the section is opened',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([1]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _advancedChar));

    // The ordinary command renders inline; both advanced ones are tucked
    // under the collapsed, warning-marked section rather than sitting between
    // the everyday controls.
    expect(find.text('Start belt'), findsWidgets);
    expect(find.text('Calibration mode'), findsNothing);
    expect(find.text('Set max speed'), findsNothing);
    expect(find.text('Advanced commands'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    await tester.tap(find.text('Advanced commands'));
    await tester.pumpAndSettle();
    // Title and send button both carry the command's name.
    expect(find.text('Calibration mode'), findsWidgets);
    expect(find.widgetWithText(ElevatedButton, 'Calibration mode'),
        findsOneWidget);
    expect(
        find.widgetWithText(ElevatedButton, 'Set max speed'), findsOneWidget);
  });

  testWidgets(
      'the first send of an advanced command confirms with the '
      'spec’s reason; cancel sends nothing', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([1]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _advancedChar));

    await tester.tap(find.text('Advanced commands'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Calibration mode'));
    await tester.pumpAndSettle();

    // The dialog carries the spec's own reason — the warning that says
    // something — with a way back out.
    expect(
        find.text('Calibration changes how command values map to real belt '
            'speed.'),
        findsOneWidget);
    expect(codec.encodeCalls, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls, isEmpty);
    expect(ble.writes, isEmpty);

    // Confirming sends; a later send of the same command does not ask again.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Calibration mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls.where((c) => c.commandName == 'calibration_mode'),
        hasLength(1));
    expect(ble.writes.single.value, [1]);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Calibration mode'));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls.where((c) => c.commandName == 'calibration_mode'),
        hasLength(2));
  });

  testWidgets(
      'an advanced command without a reason falls back to a generic '
      'warning', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([1]));
    await tester
        .pumpWidget(_wrap(ble: ble, codec: codec, specChar: _advancedChar));

    await tester.tap(find.text('Advanced commands'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Set max speed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('outlast this app'), findsOneWidget);
    expect(codec.encodeCalls, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });
}
