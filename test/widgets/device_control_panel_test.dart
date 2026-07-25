// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/providers/device_spec_provider.dart';
import 'package:opengreeniot_mobile/providers/spec_codec_provider.dart';
import 'package:opengreeniot_mobile/services/spec_codec.dart';
import 'package:opengreeniot_mobile/widgets/device_control_panel.dart';
import 'package:opengreeniot_mobile/widgets/typed_characteristic_widget.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

Widget _wrap(
  Widget child, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
  Map<String, String>? specs,
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
        if (specs != null) deviceSpecsProvider.overrideWith((ref) => specs),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('empty services renders the empty message', (tester) async {
    await tester.pumpWidget(_wrap(
      const DeviceControlPanel(deviceId: '01', deviceName: 'Dev', services: []),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));
    expect(find.text('No services found on this device.'), findsOneWidget);
  });

  testWidgets(
      'falls back to the raw browser with well-known names when no '
      'spec matches', (tester) async {
    const services = [
      BleDiscoveredService(
        uuid: '0000180f-0000-1000-8000-00805f9b34fb',
        characteristics: [],
      ),
      BleDiscoveredService(
        uuid: '00001800-0000-1000-8000-00805f9b34fb',
        characteristics: [],
      ),
    ];
    await tester.pumpWidget(_wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'Dev', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(), // no spec -> no match -> raw fallback
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('Battery Service'), findsOneWidget);
    expect(find.text('Generic Access'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsNothing);
  });

  testWidgets('renders typed controls for a matched characteristic',
      (tester) async {
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
    const spec = DeviceSpecDto(
      deviceName: 'Example Smart Bulb',
      manufacturer: 'Acme',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefix: 'ACME_',
      serviceUuids: [svcUuid],
      services: [
        ServiceDto(uuid: svcUuid, name: 'Control Service', characteristics: [
          CharacteristicDto(
            uuid: charUuid,
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
            ],
            formatFields: [],
          ),
        ]),
      ],
    );
    const services = [
      BleDiscoveredService(
        uuid: svcUuid,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: charUuid,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
    ];

    await tester.pumpWidget(_wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'ACME_Living_Room', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(
        spec: spec,
        matches: const [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            matchedServiceUuids: [svcUuid],
          ),
        ],
        encoded: Uint8List.fromList([1, 1]),
      ),
      specs: const {'assets/device_specs/example-bulb.yaml': 'dummy'},
    ));
    await tester.pumpAndSettle();

    // Service card uses the spec name, and a typed command control renders.
    expect(find.text('Control Service'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);
    expect(find.text('Power on'), findsWidgets);
  });
}
