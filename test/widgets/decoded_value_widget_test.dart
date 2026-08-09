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

  group('spec number semantics', () {
    /// Pump the browser over one decoded field and return nothing — the
    /// caller asserts on what rendered.
    Future<void> show(WidgetTester tester, DecodedValueDto value) async {
      await tester.pumpWidget(_wrap(
        const DecodedValueWidget(
          deviceId: 'd',
          serviceUuid: 's',
          specYaml: 'y',
          specChar: _statusChar,
          canRead: true,
          canNotify: false,
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(decoded: [value]),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('applies the transform and names the unit', (tester) async {
      // This view printed `display` — the raw wire integer — while scale,
      // value_offset and unit all crossed the FFI beside it. The same
      // characteristic then read "2350" here and "23.50 °C" on the entity
      // card directly above it.
      await show(
        tester,
        const DecodedValueDto(
          name: 'temperature',
          valueType: 'int',
          display: '2350',
          intValue: 2350,
          scale: 0.01,
          unit: '°C',
        ),
      );
      expect(find.text('Temperature: 23.50 °C'), findsOneWidget);
      expect(find.text('Temperature: 2350'), findsNothing);
    });

    testWidgets('applies an offset scaling', (tester) async {
      await show(
        tester,
        const DecodedValueDto(
          name: 'temp_raw',
          valueType: 'uint',
          display: '100',
          uintValue: 100,
          scale: 0.5,
          valueOffset: 85,
          unit: '°F',
        ),
      );
      expect(find.text('Temp raw: 135.0 °F'), findsOneWidget);
    });

    testWidgets('names an enumerated code and keeps the code beside it',
        (tester) async {
      // The browser shows both, unlike the entity card: someone reverse-
      // engineering a device needs the byte that produced the word.
      await show(
        tester,
        const DecodedValueDto(
          name: 'liquid_state',
          valueType: 'uint',
          display: '5',
          uintValue: 5,
          valueLabel: 'heating',
        ),
      );
      expect(find.text('Liquid state: heating (5)'), findsOneWidget);
    });

    testWidgets('says a device-setting unit is not fixed by the protocol',
        (tester) async {
      // The Inkbird iBBQ sends whichever unit the device is set to, so
      // printing "165 °C" would be a guess dressed as a fact — and printing
      // a bare "165" would imply it is dimensionless.
      await show(
        tester,
        const DecodedValueDto(
          name: 'probe_1',
          valueType: 'uint',
          display: '165',
          uintValue: 165,
          unit: 'C',
          unitSource: 'device_setting',
        ),
      );
      expect(
          find.text('Probe 1: 165 (unit set on the device)'), findsOneWidget);
    });

    testWidgets('a bool still reads as on/off, not 1', (tester) async {
      await show(
        tester,
        const DecodedValueDto(
          name: 'power_state',
          valueType: 'bool',
          display: 'on',
          boolValue: true,
        ),
      );
      expect(find.text('Power state: on'), findsOneWidget);
    });

    testWidgets('a scaled percentage fills its bar from the decoded value',
        (tester) async {
      // The bar is 0..100 in DECODED terms; driving it from the raw count
      // would peg a 50.0% reading (raw 500, scale 0.1) at full.
      await show(
        tester,
        const DecodedValueDto(
          name: 'charge',
          valueType: 'uint',
          display: '500',
          uintValue: 500,
          scale: 0.1,
          unit: '%',
        ),
      );
      expect(find.text('Charge: 50.0 %'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(0.5, 1e-9));
    });
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
