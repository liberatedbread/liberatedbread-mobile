// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Widget tests for the Rabbit Air BLE setup screen: the staged flow from
// intro through scanning, network choice and credentials to done, driven by
// a scripted provisioning service so no radio is involved.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/screens/rabbit_air_setup_screen.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_key_store.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_provision_service.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

/// A scripted provisioning service: records what the screen asked, emits
/// canned states, and can be told to fail the next [begin].
class _FakeProvisionService extends RabbitAirProvisionService {
  _FakeProvisionService()
      : super(
          codec: FakeSpecCodec(),
          keyStore: RabbitAirKeyStore(InMemorySettingsStore()),
          linkFactory: () => throw UnimplementedError('no link in this fake'),
        );

  final begun = <String>[];
  ({String ssid, String passphrase, int security})? joined;
  bool failNextBegin = false;

  static const networks = [
    RabbitAirNetwork(ssid: 'Cottage', security: 3),
    RabbitAirNetwork(ssid: 'Garage', security: 0),
  ];

  @override
  Future<void> begin(String deviceId) async {
    begun.add(deviceId);
    emit(const RabbitAirProvisionState(RabbitAirProvisionStep.connecting));
    await Future<void>.delayed(Duration.zero);
    if (failNextBegin) {
      failNextBegin = false;
      emit(state.copyWith(
          step: RabbitAirProvisionStep.failed,
          message: 'the purifier did not answer'));
      return;
    }
    emit(const RabbitAirProvisionState(
        RabbitAirProvisionStep.awaitingNetworkChoice,
        networks: networks));
  }

  @override
  Future<void> join({
    required String ssid,
    required String passphrase,
    required int security,
  }) async {
    joined = (ssid: ssid, passphrase: passphrase, security: security);
    emit(const RabbitAirProvisionState(RabbitAirProvisionStep.joining));
    await Future<void>.delayed(Duration.zero);
    emit(const RabbitAirProvisionState(RabbitAirProvisionStep.done,
        thingId: 'abcdef1234_000000000000000000', verified: true));
  }
}

void main() {
  final setupDevice = IoTDevice(
    id: '01',
    name: 'RabbitAirSetup-789A',
    rssi: -40,
    isConnectable: true,
    discoveredAt: DateTime(2026),
  );
  final someOtherDevice = IoTDevice(
    id: '02',
    name: 'SomeOtherGadget',
    rssi: -50,
    isConnectable: true,
    discoveredAt: DateTime(2026),
  );

  late _FakeProvisionService service;
  late FakeBleService ble;

  Widget wrap({IoTDevice? preselected}) => ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          rabbitAirProvisionServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(home: RabbitAirSetupScreen(device: preselected)),
      );

  setUp(() {
    service = _FakeProvisionService();
    ble = FakeBleService(devicesToEmit: [setupDevice, someOtherDevice]);
  });

  testWidgets(
      'intro explains setup mode, then the scan lists only '
      'RabbitAirSetup devices', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Put the purifier in setup mode'), findsOneWidget);
    expect(find.textContaining('Speed and Wireless'), findsOneWidget);

    await tester.tap(find.text('Find the purifier'));
    await tester.pumpAndSettle();

    expect(find.text('RabbitAirSetup-789A'), findsOneWidget);
    expect(find.text('SomeOtherGadget'), findsNothing);
  });

  testWidgets('the full flow: pick a device, pick a network, password, done',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find the purifier'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('RabbitAirSetup-789A'));
    await tester.pumpAndSettle();

    expect(service.begun, ['01']);
    expect(find.text('Choose your home Wi-Fi'), findsOneWidget);
    expect(find.text('Cottage'), findsOneWidget);

    await tester.tap(find.text('Cottage'));
    await tester.pumpAndSettle();
    expect(find.text('Password for Cottage'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.tap(find.text('Join this network'));
    await tester.pumpAndSettle();

    expect(
        service.joined, (ssid: 'Cottage', passphrase: 'hunter2', security: 3));
    expect(find.text('The purifier is on your Wi-Fi.'), findsOneWidget);
    expect(
        find.textContaining('abcdef1234_000000000000000000'), findsOneWidget);
  });

  testWidgets('an open network provisions without a password prompt',
      (tester) async {
    await tester.pumpWidget(wrap(preselected: setupDevice));
    await tester.pumpAndSettle();

    expect(service.begun, ['01'], reason: 'a preselected device skips intro');
    await tester.tap(find.text('Garage'));
    await tester.pumpAndSettle();

    expect(service.joined, (ssid: 'Garage', passphrase: '', security: 0));
    expect(find.text('The purifier is on your Wi-Fi.'), findsOneWidget);
  });

  testWidgets('a failed begin before the picker offers to try again',
      (tester) async {
    service.failNextBegin = true;
    await tester.pumpWidget(wrap(preselected: setupDevice));
    await tester.pumpAndSettle();

    expect(find.textContaining('did not answer'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(service.begun, ['01', '01']);
    expect(find.text('Choose your home Wi-Fi'), findsOneWidget);
  });
}
