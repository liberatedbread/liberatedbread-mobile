// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/health_measurement_codec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/health_measurement_codec.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/device_control_panel.dart';
import 'package:liberated_bread_mobile/widgets/health/health_measurement_panel.dart';
import 'package:liberated_bread_mobile/widgets/typed_characteristic_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';
import '../helpers/host_rust_lib.dart';

const _service = '00001810-0000-1000-8000-00805f9b34fb';
const _measurement = '00002a35-0000-1000-8000-00805f9b34fb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final String yaml;
  late final DeviceSpecDto spec;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    yaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/beurer-series800-blood-pressure.yaml',
    );
    if (rustReady) spec = await RealSpecCodec().loadDeviceSpec(yaml);
  });

  testWidgets(
    'health panel owns one paired stream and suppresses raw readers',
    (tester) async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(
        notifyStream: notify.stream,
        servicesToReturn: const [
          BleDiscoveredService(
            uuid: _service,
            characteristics: [
              BleDiscoveredCharacteristic(
                uuid: _measurement,
                canRead: false,
                canWrite: false,
                canNotify: true,
              ),
            ],
          ),
        ],
      );
      final specCodec = FakeSpecCodec(
        spec: spec,
        matches: [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            matchedServiceUuids: const [_service],
            confidence: MatchConfidence.strong,
          ),
        ],
      );
      const healthCodec = RustHealthMeasurementCodec();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            bleServiceProvider.overrideWithValue(ble),
            specCodecProvider.overrideWithValue(specCodec),
            healthMeasurementCodecProvider.overrideWithValue(healthCodec),
            deviceSpecsProvider.overrideWith((ref) => {'bp.yaml': yaml}),
            numberRegistryProvider.overrideWith(
              (ref) => const NumberRegistry(
                addressBlocks: [],
                companyIds: RegistryTable.empty,
                serviceUuids: RegistryTable.empty,
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DeviceControlPanel(
                deviceId: 'device',
                deviceName: 'PREMIUM800',
                services: [
                  BleDiscoveredService(
                    uuid: _service,
                    characteristics: [
                      BleDiscoveredCharacteristic(
                        uuid: _measurement,
                        canRead: false,
                        canWrite: false,
                        canNotify: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (var index = 0; index < 10; index++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.byType(HealthMeasurementPanel), findsOneWidget);
      expect(find.byType(TypedCharacteristicWidget), findsNothing);
      expect(ble.liveSubscriberCount[_measurement], 1);
      expect(
        find.text('Shown in the measurement panel above.'),
        findsOneWidget,
      );
      expect(find.textContaining('Systolic Pressure'), findsNothing);

      notify.add([
        0x02,
        0x00,
        0x78,
        0x00,
        0x50,
        0x00,
        0x5D,
        0xEA,
        0x07,
        11,
        8,
        14,
        32,
        15,
        0x00,
        0x48,
        1,
        0,
        0x40,
      ]);
      for (var index = 0; index < 50; index++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.text('120/80').evaluate().isNotEmpty) break;
      }
      expect(find.text('120/80'), findsOneWidget);
      expect(find.text('Pulse 72 bpm'), findsOneWidget);
      expect(ble.liveSubscriberCount[_measurement], 1);
    },
  );
}
