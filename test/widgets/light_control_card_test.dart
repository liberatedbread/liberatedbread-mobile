// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/decoded_value_widget.dart';
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
}) => EntityActionDto(
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
  options: const [],
  name: 'LED Strip',
  platform: 'light',
  canNotify: false,
  hasFormat: false,
  onWhenNonzero: false,
  actions: [
    _action(
      'set_brightness',
      'set_brightness',
      userParams: const ['brightness'],
      min: 0,
      max: 100,
    ),
    _action(
      'set_color',
      'set_rgb_color',
      userParams: const ['red', 'green', 'blue'],
    ),
  ],
  variants: const [],
);

/// A spec whose `set_brightness` parameter declares [unit] (or none), bound
/// where [_stripEntity]'s actions point.
DeviceSpecDto _specWithBrightnessUnit(
  String? unit, {
  double? scale,
}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Strip',
  manufacturer: 'Test Co',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_cmdService],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const [],
  services: [
    ServiceDto(
      // Upper-case: the lookup folds, as the discovered spelling may differ.
      uuid: _cmdService.toUpperCase(),
      name: 'Control',
      characteristics: [
        CharacteristicDto(
          uuid: _cmdChar,
          name: 'Command',
          canRead: false,
          canWrite: true,
          canNotify: false,
          commands: [
            CommandDto(
              name: 'set_brightness',
              description: 'Set brightness',
              isFixed: false,
              isEncodable: true,
              unsupportedEncoding: null,
              advanced: false,
              parameters: [
                ParameterDto(
                  name: 'brightness',
                  valueType: 'uint8',
                  min: 0,
                  max: 100,
                  unit: unit,
                  scale: scale,
                  userSettable: true,
                ),
              ],
            ),
          ],
          formatFields: const [],
        ),
      ],
    ),
  ],
);

Widget _wrap(
  EntityDto entity, {
  required FakeSpecCodec codec,
  required FakeBleService ble,
  String? stateServiceUuid,
  DeviceSpecDto? spec,
}) => ProviderScope(
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
          spec: spec,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('renders only the controls whose roles resolved', (tester) async {
    final codec = FakeSpecCodec();
    await tester.pumpWidget(
      _wrap(_stripEntity(), codec: codec, ble: FakeBleService()),
    );
    await tester.pumpAndSettle();

    // No power action resolved (elk's on/off byte is ambiguous), so no
    // toggle and no On/Off buttons — but brightness and color are live.
    expect(find.byType(Switch), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'On'), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('tapping a swatch sends the color command with RGB params', (
    tester,
  ) async {
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

  testWidgets('the brightness figure carries the unit the spec declares, and '
      'none it does not', (tester) async {
    // It used to be guessed from the bounds: 0..100 read as "%", so
    // elk-bledom's unitless brightness said "100%" here while its typed
    // command card said a bare 100. Fails on the bounds guess: the
    // unitless 0..100 spec below showed "100%".
    await tester.pumpWidget(
      _wrap(
        _stripEntity(),
        codec: FakeSpecCodec(),
        ble: FakeBleService(),
        spec: _specWithBrightnessUnit(null),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('100'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);

    // yeelight-cube-lamp declares `unit: "%"`; spelled as the typed card
    // spells it.
    await tester.pumpWidget(
      _wrap(
        _stripEntity(),
        codec: FakeSpecCodec(),
        ble: FakeBleService(),
        spec: _specWithBrightnessUnit('%'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('100 %'), findsOneWidget);

    // A `percent` spelling goes through the same display table.
    await tester.pumpWidget(
      _wrap(
        _stripEntity(),
        codec: FakeSpecCodec(),
        ble: FakeBleService(),
        spec: _specWithBrightnessUnit('percent'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('100 %'), findsOneWidget);
  });

  testWidgets('a scaled brightness shows no unit beside its raw value', (
    tester,
  ) async {
    // The unit names raw * scale, and the slider shows the raw value it
    // sends: a 0..100 raw at scale 0.5 said "100 %" for what is 50 %. Fails
    // on the old card, which labelled the raw number with the unit.
    await tester.pumpWidget(
      _wrap(
        _stripEntity(),
        codec: FakeSpecCodec(),
        ble: FakeBleService(),
        spec: _specWithBrightnessUnit('%', scale: 0.5),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('100'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('a brightness sent from the card re-reads the Status in the '
      'same service', (tester) async {
    // The light's own service folds under this card, so its Status reading
    // stayed on its first read after a send from here — only the typed
    // command card bumped the re-read. Fails on the old card: one read.
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([9]));
    final ble = FakeBleService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(codec),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  LightControlCard(
                    deviceId: 'd',
                    stateServiceUuid: null,
                    entity: _stripEntity(),
                    specYaml: 'y',
                  ),
                  const DecodedValueWidget(
                    deviceId: 'd',
                    // Spelled differently from the action's UUID: the key
                    // folds, so the reader and writer still agree.
                    serviceUuid: '0000FFF0-0000-1000-8000-00805F9B34FB',
                    specYaml: 'y',
                    specChar: CharacteristicDto(
                      uuid: _stateChar,
                      name: 'Status',
                      canRead: true,
                      canWrite: false,
                      canNotify: false,
                      commands: [],
                      formatFields: [],
                    ),
                    canRead: true,
                    canNotify: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    int statusReads() =>
        ble.reads.where((r) => r.charUuid == _stateChar).length;
    expect(statusReads(), 1);

    await tester.drag(find.byType(Slider), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(ble.writes, hasLength(1));
    expect(statusReads(), 2);
  });

  testWidgets(
    'brightness riding the color command stages until a color is known',
    (tester) async {
      // ember's LED: no dedicated brightness command; set_led_color carries
      // brightness. Committing the slider before any color is known must NOT
      // invent a color to send.
      final entity = EntityDto(
        options: const [],
        name: 'LED',
        platform: 'light',
        canNotify: false,
        hasFormat: false,
        onWhenNonzero: false,
        actions: [
          _action(
            'set_color',
            'set_led_color',
            userParams: const ['red', 'green', 'blue', 'brightness'],
          ),
        ],
        variants: const [],
      );
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([0]));
      final ble = FakeBleService();
      await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
      await tester.pumpAndSettle();

      expect(
        find.byType(Slider),
        findsOneWidget,
        reason: 'the color command carries brightness, so the slider shows',
      );

      await tester.drag(find.byType(Slider), const Offset(-100, 0));
      await tester.pumpAndSettle();
      expect(
        codec.encodeCalls,
        isEmpty,
        reason: 'no color known yet — nothing safe to send',
      );

      final swatches = find.byWidgetPredicate(
        (w) => w is InkWell && w.borderRadius == BorderRadius.circular(19),
      );
      await tester.tap(swatches.at(2));
      await tester.pumpAndSettle();
      expect(codec.encodeCalls, hasLength(1));
      expect(codec.encodeCalls.single.params.containsKey('brightness'), isTrue);

      await tester.drag(find.byType(Slider), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(
        codec.encodeCalls,
        hasLength(2),
        reason: 'with a color known, brightness commits re-send the color',
      );
      expect(codec.encodeCalls.last.commandName, 'set_led_color');
    },
  );

  testWidgets('power toggle sends and reports the assumed state', (
    tester,
  ) async {
    final entity = EntityDto(
      options: const [],
      name: 'Bulb',
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        _action('turn_on', 'power_on'),
        _action('turn_off', 'power_off'),
      ],
      variants: const [],
    );
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xCC]));
    final ble = FakeBleService();
    await tester.pumpWidget(_wrap(entity, codec: codec, ble: ble));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'power_on');
    expect(
      find.text('On (sent)'),
      findsNothing,
      reason: 'without live state the status stays a plain Ready line',
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('seeds control positions from decoded device state', (
    tester,
  ) async {
    // example-bulb's shape: readable power/brightness/color. The card must
    // open showing what the device reports, not defaults.
    final entity = EntityDto(
      options: const [],
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
        _action(
          'set_brightness',
          'set_brightness',
          userParams: const ['brightness'],
          min: 0,
          max: 255,
        ),
        _action(
          'set_color',
          'set_color',
          userParams: const ['red', 'green', 'blue'],
        ),
      ],
      variants: const [],
    );
    final codec = FakeSpecCodec(
      decoded: const [
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
          rawNumber: 80.0,
          decodedNumber: 80.0,
          decodedText: '80',
          decimals: 0,
        ),
        DecodedValueDto(
          name: 'red',
          valueType: 'uint',
          display: '255',
          uintValue: 255,
          rawNumber: 255.0,
          decodedNumber: 255.0,
          decodedText: '255',
          decimals: 0,
        ),
        DecodedValueDto(
          name: 'green',
          valueType: 'uint',
          display: '0',
          uintValue: 0,
          rawNumber: 0.0,
          decodedNumber: 0.0,
          decodedText: '0',
          decimals: 0,
        ),
        DecodedValueDto(
          name: 'blue',
          valueType: 'uint',
          display: '0',
          uintValue: 0,
          rawNumber: 0.0,
          decodedNumber: 0.0,
          decodedText: '0',
          decimals: 0,
        ),
      ],
    );
    final ble = FakeBleService(
      readValues: const {
        _stateChar: [1, 80, 255, 0, 0],
      },
    );

    await tester.pumpWidget(
      _wrap(entity, codec: codec, ble: ble, stateServiceUuid: 's'),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 80);
    expect(find.text('On'), findsOneWidget);
  });
  testWidgets(
    'a parameter the card has no value for is omitted, never zeroed',
    (tester) async {
      // A spec naming its knob something this card does not know (`warmth`)
      // used to get 0.0 written to the hardware — a real value nobody chose,
      // sent silently while the card looked like it had worked. Omitting it
      // hands the choice to the encoder: the spec's own default, or a visible
      // ParameterMissing.
      final entity = EntityDto(
        options: const [],
        name: 'Tunable Strip',
        platform: 'light',
        canNotify: false,
        hasFormat: false,
        onWhenNonzero: false,
        actions: [
          _action(
            'set_color',
            'set_rgb_color',
            userParams: const ['red', 'green', 'blue', 'warmth'],
          ),
        ],
        variants: const [],
      );
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([1]));
      await tester.pumpWidget(
        _wrap(entity, codec: codec, ble: FakeBleService()),
      );
      await tester.pumpAndSettle();

      final swatches = find.byWidgetPredicate(
        (w) => w is InkWell && w.borderRadius == BorderRadius.circular(19),
      );
      await tester.tap(swatches.at(2));
      await tester.pumpAndSettle();

      final sent = codec.encodeCalls.single.params;
      expect(sent.keys, containsAll(<String>['red', 'green', 'blue']));
      expect(
        sent.containsKey('warmth'),
        isFalse,
        reason: 'an unknown parameter must not be sent as 0',
      );
    },
  );
}
