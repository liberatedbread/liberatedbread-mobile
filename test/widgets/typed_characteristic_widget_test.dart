// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/decoded_value_widget.dart';
import 'package:liberated_bread_mobile/widgets/raw_characteristic_widget.dart';
import 'package:liberated_bread_mobile/widgets/typed_characteristic_widget.dart';
import 'package:liberated_bread_mobile/widgets/typed_command_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _cmdChar = CharacteristicDto(
  uuid: 'c',
  name: 'Command',
  canRead: false,
  canWrite: true,
  canNotify: false,
  commands: [
    CommandDto(
        name: 'power_on',
        description: '',
        parameters: [],
        isFixed: true,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false),
  ],
  formatFields: [],
);

const _fmtChar = CharacteristicDto(
  uuid: 'c',
  name: 'Status',
  canRead: true,
  canWrite: false,
  canNotify: false,
  commands: [],
  formatFields: [
    FormatFieldDto(name: 'x', fieldType: 'uint8', offset: 0, length: 1),
  ],
);

const _plainChar = CharacteristicDto(
  uuid: 'c',
  name: 'Plain',
  canRead: true,
  canWrite: false,
  canNotify: false,
  commands: [],
  formatFields: [],
);

Widget _wrap(Widget child) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        specCodecProvider.overrideWithValue(FakeSpecCodec(decoded: const [])),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

TypedCharacteristicWidget _widget(
  CharacteristicDto specChar,
  BleDiscoveredCharacteristic discovered,
) =>
    TypedCharacteristicWidget(
      deviceId: 'd',
      serviceUuid: 's',
      specYaml: 'y',
      specChar: specChar,
      discovered: discovered,
    );

void main() {
  testWidgets('writable + commands renders TypedCommandWidget', (tester) async {
    await tester.pumpWidget(_wrap(_widget(
      _cmdChar,
      const BleDiscoveredCharacteristic(
          uuid: 'c', canRead: false, canWrite: true, canNotify: false),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(TypedCommandWidget), findsOneWidget);
    expect(find.byType(DecodedValueWidget), findsNothing);
  });

  testWidgets('readable + format fields renders DecodedValueWidget',
      (tester) async {
    await tester.pumpWidget(_wrap(_widget(
      _fmtChar,
      const BleDiscoveredCharacteristic(
          uuid: 'c', canRead: true, canWrite: false, canNotify: false),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(DecodedValueWidget), findsOneWidget);
    expect(find.byType(TypedCommandWidget), findsNothing);
  });

  testWidgets('no typed metadata falls back to RawCharacteristicWidget',
      (tester) async {
    await tester.pumpWidget(_wrap(_widget(
      _plainChar,
      const BleDiscoveredCharacteristic(
          uuid: 'c', canRead: true, canWrite: false, canNotify: false),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(RawCharacteristicWidget), findsOneWidget);
  });
}
