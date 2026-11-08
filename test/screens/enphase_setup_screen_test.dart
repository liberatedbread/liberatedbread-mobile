// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/enphase_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/services/enphase_ble_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

class _Codec extends FakeSpecCodec {
  _Codec()
    : super(
        specByYaml: {
          'enphase': DeviceSpecDto(
            nameMatchers: const [],
            platformFallbackTypes: const [],
            txtMatchGroups: const [],
            hiddenEntityNames: const [],
            deviceName: 'Enphase IQ Battery / IQ System Controller (BLE)',
            manufacturer: 'Enphase Energy',
            manufacturerStatus: 'active',
            protocol: 'ble',
            category: 'energy',
            localNamePrefixes: const ['Enpower/', 'Encharg/'],
            localNames: const [],
            serviceUuids: const ['53da53b9-0447-425a-b9ea-9837505eb59a'],
            companyIds: Uint16List(0),
            macPrefixes: const [],
            mdnsServiceTypes: const [],
            ssdpSearchTargets: const [],
            lanProtocols: const [],
            defaultPort: null,
            entities: const [],
            services: const [],
          ),
        },
        scanMatches: (_) => [
          ScanMatch(
            specIndex: 0,
            deviceName: 'Enphase IQ Battery / IQ System Controller (BLE)',
            manufacturer: 'Enphase Energy',
            confidence: MatchConfidence.strong,
            matchedByNamePrefix: true,
            matchedServiceUuids: const ['53da53b9-0447-425a-b9ea-9837505eb59a'],
            matchedCompanyIds: Uint16List(0),
            matchedMacPrefix: null,
            matchedServiceTypes: const [],
          ),
        ],
      );
}

class _Client implements EnphaseClient {
  var unlockCalls = 0;

  @override
  Future<EnphaseSessionReport> unlockAndRead() async {
    unlockCalls++;
    return const EnphaseSessionReport(
      replies: [
        EnphaseStatusReply(type: 4, sourceInterface: 0, payload: [1]),
        EnphaseStatusReply(type: 5, sourceInterface: 0, payload: [0, 2]),
        EnphaseStatusReply(
          type: 8,
          sourceInterface: 0,
          payload: [0x47, 0x57, 0x31, 0x32, 0x33],
        ),
      ],
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('Enphase opens its unlock workflow instead of the GATT client', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ble = FakeBleService();
    final client = _Client();
    final device = IoTDevice(
      id: '04:0D:84:AA:BB:CC',
      name: 'Enpower/SERIAL',
      rssi: -40,
      isConnectable: true,
      discoveredAt: DateTime(2026),
      serviceUuids: const ['53da53b9-0447-425a-b9ea-9837505eb59a'],
    );
    final container = ProviderContainer(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        enphaseClientProvider.overrideWithValue((_) => client),
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(_Codec()),
        deviceSpecsProvider.overrideWith(
          (ref) => {
            'vendor/protocol-specs/device-specs/devices/'
                    'enphase-iqbattery-ble.yaml':
                'enphase',
          },
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(scanGuessProvider(ScanIdentity.of(device)).future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: DeviceScreen(device: device)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enphase Bluetooth access'), findsOneWidget);
    expect(find.text('Unlock & read status'), findsOneWidget);
    expect(ble.connectedIds, isEmpty);
    expect(ble.subscriptions, isEmpty);

    await tester.tap(find.text('Unlock & read status'));
    await tester.pumpAndSettle();

    expect(client.unlockCalls, 1);
    expect(find.text('Unlocked over encrypted XBee link'), findsOneWidget);
    expect(find.text('Zigbee pairing status'), findsOneWidget);
    expect(find.text('Zigbee commissioning status'), findsOneWidget);
    expect(find.text('Gateway serial response'), findsOneWidget);
    expect(find.text('47 57 31 32 33'), findsOneWidget);
    expect(ble.connectedIds, isEmpty);
    expect(ble.subscriptions, isEmpty);
  });
}
