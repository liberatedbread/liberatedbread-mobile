// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_choice_store.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/device_control_panel.dart';
import 'package:liberated_bread_mobile/widgets/typed_characteristic_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

Future<Widget> _wrap(
  Widget child, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
  Map<String, String>? specs,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bleServiceProvider.overrideWithValue(ble),
      specCodecProvider.overrideWithValue(codec),
      if (specs != null) deviceSpecsProvider.overrideWith((ref) => specs),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('empty services renders the empty message', (tester) async {
    await tester.pumpWidget(await _wrap(
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
    await tester.pumpWidget(await _wrap(
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
      entities: <EntityDto>[],
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

    await tester.pumpWidget(await _wrap(
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

  testWidgets(
      'equally-matched specs show the chooser; picking one persists and '
      'renders its typed controls', (tester) async {
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
    // Two white-label brands sharing one GATT platform service.
    const brandA = DeviceSpecDto(
      deviceName: 'Brand A Lights',
      manufacturer: 'Vendor A',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [svcUuid],
      entities: <EntityDto>[],
      services: [
        ServiceDto(uuid: svcUuid, name: 'A Control', characteristics: [
          CharacteristicDto(
            uuid: charUuid,
            name: 'Command',
            canRead: false,
            canWrite: true,
            canNotify: false,
            commands: [
              CommandDto(
                name: 'power_on',
                description: 'On',
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
    const brandB = DeviceSpecDto(
      deviceName: 'Brand B Lights',
      manufacturer: 'Vendor B',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [svcUuid],
      entities: <EntityDto>[],
      services: [
        ServiceDto(uuid: svcUuid, name: 'B Control', characteristics: []),
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

    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: 'AA:BB', deviceName: 'Mystery', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(
        specByYaml: const {'yaml-a': brandA, 'yaml-b': brandB},
        matches: const [
          MatchResult(
            spec: brandA,
            matchedByNamePrefix: false,
            matchedServiceUuids: [svcUuid],
          ),
          MatchResult(
            spec: brandB,
            matchedByNamePrefix: false,
            matchedServiceUuids: [svcUuid],
          ),
        ],
        encoded: Uint8List.fromList([1, 1]),
      ),
      specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
    ));
    await tester.pumpAndSettle();

    // The tie renders a chooser with both brands; raw controls stay below
    // (the service card shows a generic name, not either brand's).
    expect(find.text('Which device is this?'), findsOneWidget);
    expect(find.text('Brand A Lights'), findsOneWidget);
    expect(find.text('Brand B Lights'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsNothing);

    await tester.tap(find.text('Brand A Lights'));
    await tester.pumpAndSettle();

    // Chooser gone, chosen spec's names and typed controls in place.
    expect(find.text('Which device is this?'), findsNothing);
    expect(find.text('A Control'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);

    // And the choice was persisted for the next connection.
    final store = SpecChoiceStore(await SharedPreferences.getInstance());
    expect(store.load(), {'AA:BB': 'Brand A Lights|Vendor A'});
  });
}
