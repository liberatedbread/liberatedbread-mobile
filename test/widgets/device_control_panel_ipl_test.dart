// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/ipl_codec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/device_control_panel.dart';
import 'package:liberated_bread_mobile/widgets/ipl_setup_panel.dart';
import 'package:liberated_bread_mobile/widgets/typed_characteristic_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ipl_codec.dart';
import '../fakes/fake_spec_codec.dart';
import '../helpers/host_rust_lib.dart';

const _specService = '0000fff0-0000-1000-8000-00805f9b34fb';
const _actualService = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _command = '0000fff1-0000-1000-8000-00805f9b34fb';
const _activation = '00000a20-0000-1000-8000-00805f9b34fb';
const _wakeup = '00000a30-0000-1000-8000-00805f9b34fb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final String yaml;
  late final DeviceSpecDto spec;
  late final String braunYaml;
  late final DeviceSpecDto braunSpec;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    yaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/foreo-peach-2.yaml',
    );
    braunYaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/braun-silk-expert-pro5.yaml',
    );
    if (rustReady) {
      spec = await RealSpecCodec().loadDeviceSpec(yaml);
      braunSpec = await RealSpecCodec().loadDeviceSpec(braunYaml);
    }
  });

  testWidgets('unknown service keeps typed IPL commands usable', (
    tester,
  ) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    expect(spec.protocolHandler, 'ipl_foreo');
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ble = FakeBleService(
      readValues: const {
        _activation: [1],
        _wakeup: [1],
      },
      servicesToReturn: const [
        BleDiscoveredService(uuid: _specService, characteristics: []),
        BleDiscoveredService(
          uuid: _actualService,
          characteristics: [
            BleDiscoveredCharacteristic(
              uuid: _command,
              canRead: true,
              canWrite: true,
              canNotify: false,
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
          matchedServiceUuids: const [],
          confidence: MatchConfidence.likely,
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(specCodec),
          iplCodecProvider.overrideWithValue(FakeIplCodec()),
          deviceSpecsProvider.overrideWith((ref) => {'foreo.yaml': yaml}),
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
              deviceId: 'AA:BB:CC:DD:EE:FF',
              deviceName: 'PEACH2',
              services: [
                BleDiscoveredService(uuid: _specService, characteristics: []),
                BleDiscoveredService(
                  uuid: _actualService,
                  characteristics: [
                    BleDiscoveredCharacteristic(
                      uuid: _command,
                      canRead: true,
                      canWrite: true,
                      canNotify: false,
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

    final visibleText = find
        .byType(Text)
        .evaluate()
        .map((element) => (element.widget as Text).data)
        .toList();
    expect(find.byType(IplSetupPanel), findsOneWidget, reason: '$visibleText');
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);
    // Pro is an advanced write in the spec (the stock app gates it behind a
    // subscription and no capture has made it), so it stays out of the panel
    // until advanced controls are on; Basic is a plain, confirmed write.
    expect(
      find.widgetWithText(ElevatedButton, 'Set removal mode pro'),
      findsNothing,
    );
    final basic = find.widgetWithText(ElevatedButton, 'Set removal mode basic');
    expect(basic, findsOneWidget);
    await tester.ensureVisible(basic);
    await tester.tap(basic);
    await tester.pump();
    expect(specCodec.encodeCalls.single.commandName, 'set_removal_mode_basic');
    expect(specCodec.encodeCalls.single.serviceUuid, _actualService);
  });

  testWidgets('Braun setup actions do not leak into generic commands', (
    tester,
  ) async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    const braunCommand = 'a0f03c00-5047-4d53-8208-4f72616c2d42';
    const services = [
      BleDiscoveredService(uuid: braunCommand, characteristics: []),
      BleDiscoveredService(
        uuid: _actualService,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: braunCommand,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
    ];
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ble = FakeBleService(servicesToReturn: services);
    final specCodec = FakeSpecCodec(
      spec: braunSpec,
      matches: [
        MatchResult(
          spec: braunSpec,
          matchedByNamePrefix: true,
          matchedServiceUuids: const [],
          confidence: MatchConfidence.likely,
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(specCodec),
          iplCodecProvider.overrideWithValue(FakeIplCodec()),
          deviceSpecsProvider.overrideWith((ref) => {'braun.yaml': braunYaml}),
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
              deviceId: 'AA:BB:CC:DD:EE:FF',
              deviceName: 'Silk-expert Pro 5',
              services: services,
            ),
          ),
        ),
      ),
    );
    for (var index = 0; index < 10; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.byType(IplSetupPanel), findsOneWidget);
    expect(find.text('IPL setup commands'), findsOneWidget);
    expect(find.text('Measure skin tone'), findsOneWidget);
    expect(find.text('Start patch test'), findsOneWidget);
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, 'Start patch test'),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Start patch test'));
    await tester.pumpAndSettle();
    expect(find.text('Start a patch test?'), findsOneWidget);
    expect(specCodec.encodeCalls, isEmpty);
  });
}
