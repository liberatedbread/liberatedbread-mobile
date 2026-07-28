// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/ha_sensor_forwarder.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/decoded_value_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ha_api_client.dart';
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

  testWidgets('forwards decoded values to Home Assistant when registered',
      (tester) async {
    final ble = FakeBleService(readValues: const {
      '0000fff2-0000-1000-8000-00805f9b34fb': [1, 80],
    });
    final codec = FakeSpecCodec(decoded: const [
      DecodedValueDto(
          name: 'brightness', valueType: 'uint', display: '80', uintValue: 80),
    ]);
    final api = FakeHaApiClient();
    final forwarder = HaSensorForwarder(
      api: api,
      readConfig: () async => const HaConfig(
        baseUrl: 'http://ha.local:8123',
        token: 't',
        deviceId: 'app1',
        webhookId: 'wh1',
      ),
      minSendInterval: Duration.zero,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
        haForwarderProvider.overrideWithValue(forwarder),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: DecodedValueWidget(
            deviceId: 'd',
            serviceUuid: 's',
            specYaml: 'y',
            specChar: _statusChar,
            canRead: true,
            canNotify: false,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await forwarder.idle;

    expect(api.registeredSensors, hasLength(1));
    expect(api.registeredSensors.single.uniqueId, 'ogiot_d_fff2_brightness');
    expect(api.stateUpdates, hasLength(1));
    expect(api.stateUpdates.single.single.state, 80);
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
