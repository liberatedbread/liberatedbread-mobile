// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// End-to-end error flow: a failing BleService should surface an error
// screen with a functional Retry button.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/screens/device_screen.dart';
import 'package:opengreeniot_mobile/services/ble_service.dart';

class _FailingBleService implements BleService {
  int connectCalls = 0;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)}) =>
      const Stream.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    connectCalls++;
    throw StateError('mock connect failure');
  }

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      const Stream.empty();

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async =>
      [];

  @override
  Future<List<int>> readCharacteristic(String d, String s, String c) async =>
      [];

  @override
  Future<void> writeCharacteristic(
      String d, String s, String c, List<int> v) async {}

  @override
  Stream<List<int>> subscribeCharacteristic(String d, String s, String c) =>
      const Stream.empty();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('retry re-runs a failing connect', (tester) async {
    final fake = _FailingBleService();
    final device = IoTDevice(
      id: 'AA:BB:CC:DD:EE:01',
      name: 'ACME_TEST',
      rssi: -40,
      isConnectable: true,
      discoveredAt: DateTime.now(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bleServiceProvider.overrideWithValue(fake)],
        child: MaterialApp(home: DeviceScreen(device: device)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('mock connect failure'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(fake.connectCalls, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(fake.connectCalls, 2);
  });
}
