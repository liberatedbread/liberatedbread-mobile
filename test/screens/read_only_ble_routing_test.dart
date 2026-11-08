// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A device under a read-only BLE handler opens its own panel, before anything
// connects, and so can never reach the generic client's controls or raw write
// tools.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _name = 'Yummly Smart Thermometer';
const _maker = 'Yummly';

class _Codec extends FakeSpecCodec {
  _Codec(String handler)
    : super(
        specByYaml: {
          'yummly': DeviceSpecDto(
            protocolHandler: handler,
            nameMatchers: const [],
            platformFallbackTypes: const [],
            txtMatchGroups: const [],
            hiddenEntityNames: const [],
            deviceName: _name,
            manufacturer: _maker,
            manufacturerStatus: 'shutdown',
            protocol: 'ble',
            category: 'sensor',
            localNamePrefixes: const [],
            localNames: const ['Yummly T1'],
            serviceUuids: const [],
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
            deviceName: _name,
            manufacturer: _maker,
            confidence: MatchConfidence.strong,
            matchedByNamePrefix: true,
            matchedServiceUuids: const [],
            matchedCompanyIds: Uint16List(0),
            matchedMacPrefix: null,
            matchedServiceTypes: const [],
          ),
        ],
      );
}

void main() {
  Future<FakeBleService> open(WidgetTester tester, String handler) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ble = FakeBleService();
    final device = IoTDevice(
      id: 'AA:BB:CC:DD:EE:FF',
      name: 'Yummly T1',
      rssi: -40,
      isConnectable: true,
      discoveredAt: DateTime(2026),
    );
    final container = ProviderContainer(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(_Codec(handler)),
        deviceSpecsProvider.overrideWith(
          (ref) => {'devices/yummly-smart-thermometer.yaml': 'yummly'},
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
    return ble;
  }

  testWidgets('a read-only handler opens its panel without connecting', (
    tester,
  ) async {
    final ble = await open(tester, 'yummly_xw2_tlv');
    expect(find.text('Start reading'), findsOneWidget);
    expect(find.text('Read-only'), findsWidgets);
    expect(ble.connectedIds, isEmpty, reason: 'nothing connects until asked');
    expect(ble.subscriptions, isEmpty);
    expect(ble.writes, isEmpty);
  });

  testWidgets('AC Infinity takes the same path', (tester) async {
    final ble = await open(tester, 'acinfinity_a5');
    expect(find.text('Start reading'), findsOneWidget);
    expect(ble.connectedIds, isEmpty);
    expect(ble.writes, isEmpty);
  });
}
