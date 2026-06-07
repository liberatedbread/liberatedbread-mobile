// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/providers/spec_codec_provider.dart';
import 'package:opengreeniot_mobile/services/spec_codec.dart';
import 'package:opengreeniot_mobile/widgets/decoded_value_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _statusChar = CharacteristicDto(
  uuid: '0000fff2-0000-1000-8000-00805f9b34fb',
  name: 'Status',
  canRead: true,
  canWrite: false,
  canNotify: true,
  commands: [],
  formatFields: [
    FormatFieldDto(
        name: 'power_state', fieldType: 'bool', offset: 0, length: 1),
    FormatFieldDto(
        name: 'brightness', fieldType: 'uint8', offset: 1, length: 1),
  ],
);

const _batteryChar = CharacteristicDto(
  uuid: '00002a19-0000-1000-8000-00805f9b34fb',
  name: 'Battery Level',
  canRead: true,
  canWrite: false,
  canNotify: false,
  commands: [],
  formatFields: [
    FormatFieldDto(
        name: 'battery_percent', fieldType: 'uint8', offset: 0, length: 1),
  ],
);

Widget _wrap(
  Widget child, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('reads then shows decoded named fields', (tester) async {
    final ble = FakeBleService(readValues: const {
      '0000fff2-0000-1000-8000-00805f9b34fb': [1, 80],
    });
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
          name: 'power_state',
          valueType: 'bool',
          display: 'on',
          boolValue: true),
      DecodedValueDto(
          name: 'brightness', valueType: 'uint', display: '80', uintValue: 80),
    ]);

    await tester.pumpWidget(_wrap(
      const DecodedValueWidget(
        deviceId: 'd',
        serviceUuid: 's',
        specYaml: 'y',
        specChar: _statusChar,
        canRead: true,
        canNotify: false,
      ),
      ble: ble,
      codec: codec,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Power state: on'), findsOneWidget);
    expect(find.text('Brightness: 80'), findsOneWidget);
  });

  testWidgets('renders a progress bar for battery-style fields',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
          name: 'battery_percent',
          valueType: 'uint',
          display: '85',
          uintValue: 85),
    ]);

    await tester.pumpWidget(_wrap(
      const DecodedValueWidget(
        deviceId: 'd',
        serviceUuid: 's',
        specYaml: 'y',
        specChar: _batteryChar,
        canRead: true,
        canNotify: false,
      ),
      ble: ble,
      codec: codec,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Battery percent: 85'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('updates on a notify event', (tester) async {
    final controller = StreamController<List<int>>.broadcast();
    addTearDown(controller.close);
    final ble = FakeBleService(notifyStream: controller.stream);
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
          name: 'brightness', valueType: 'uint', display: '42', uintValue: 42),
    ]);

    await tester.pumpWidget(_wrap(
      const DecodedValueWidget(
        deviceId: 'd',
        serviceUuid: 's',
        specYaml: 'y',
        specChar: _statusChar,
        canRead: false,
        canNotify: true,
      ),
      ble: ble,
      codec: codec,
    ));
    await tester.pump();
    expect(find.text('Brightness: 42'), findsNothing);

    controller.add([0, 42]);
    await tester.pumpAndSettle();
    expect(find.text('Brightness: 42'), findsOneWidget);
  });
}
