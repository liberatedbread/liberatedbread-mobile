// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/classic_printer_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/services/classic_spp_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _ready = BrotherQlStatusDto(
  mediaWidthMm: 62,
  mediaType: 'continuous',
  mediaLengthMm: 0,
  statusType: 0,
  phase: 0,
  errors: [],
  readyToPrint: true,
);

class _Codec extends FakeSpecCodec {
  _Codec()
    : super(
        specByYaml: {
          'ql': DeviceSpecDto(
            nameMatchers: const [],
            platformFallbackTypes: const [],
            txtMatchGroups: const [],
            hiddenEntityNames: const [],
            deviceName: 'Brother QL-1110NWB Label Printer',
            manufacturer: 'Brother Industries',
            manufacturerStatus: 'active',
            protocol: 'wifi',
            category: 'printer',
            localNamePrefixes: const ['QL-1110NWB'],
            localNames: const [],
            serviceUuids: const [],
            companyIds: Uint16List(0),
            macPrefixes: const [],
            mdnsServiceTypes: const [],
            ssdpSearchTargets: const [],
            lanProtocols: const [],
            defaultPort: 9100,
            entities: const [],
            services: const [],
            protocolHandler: 'brother_ql_raster',
          ),
        },
        scanMatches: (_) => [
          ScanMatch(
            specIndex: 0,
            deviceName: 'Brother QL-1110NWB Label Printer',
            manufacturer: 'Brother Industries',
            confidence: MatchConfidence.strong,
            matchedByNamePrefix: true,
            matchedServiceUuids: const [],
            matchedCompanyIds: Uint16List(0),
            matchedMacPrefix: null,
            matchedServiceTypes: const [],
          ),
        ],
      );

  @override
  Future<Uint8List> brotherQlStatusRequest() async =>
      Uint8List.fromList(const [0x1b, 0x69, 0x53]);

  @override
  Future<BrotherQlStatusDto> decodeBrotherQlStatus({
    required List<int> reply,
  }) async => _ready;
}

class _Spp implements ClassicSppService {
  int pairCalls = 0;
  int requestCalls = 0;

  @override
  Future<void> pair(String address) async => pairCalls++;

  @override
  Future<Uint8List> request(
    String address,
    List<int> payload, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    requestCalls++;
    return Uint8List(32);
  }

  @override
  Future<List<Uint8List>> sendJob(
    String address,
    List<int> job, {
    required int stopOffset,
    required Set<int> stopValues,
    Duration settle = Duration.zero,
    Duration timeout = const Duration(seconds: 60),
  }) async => const [];
}

void main() {
  testWidgets('a known Classic QL skips GATT and verifies over SPP', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ble = FakeBleService();
    final spp = _Spp();
    final device = IoTDevice(
      id: '60:98:66:AA:BB:CC',
      name: 'QL-1110NWB0000',
      rssi: -40,
      isConnectable: true,
      discoveredAt: DateTime(2026),
      serviceUuids: const ['00001101-0000-1000-8000-00805f9b34fb'],
    );

    final container = ProviderContainer(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        classicSppServiceProvider.overrideWithValue(spp),
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(_Codec()),
        deviceSpecsProvider.overrideWith((ref) => {'ql.yaml': 'ql'}),
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

    expect(find.text('Bluetooth Classic printer'), findsOneWidget);
    expect(ble.connectedIds, isEmpty);

    await tester.tap(find.text('Pair & verify'));
    await tester.pumpAndSettle();

    expect(spp.pairCalls, 1);
    expect(spp.requestCalls, 1);
    expect(find.text('Ready over Bluetooth SPP'), findsOneWidget);
    expect(find.text('62 mm continuous media'), findsOneWidget);
    expect(ble.connectedIds, isEmpty);
  });
}
