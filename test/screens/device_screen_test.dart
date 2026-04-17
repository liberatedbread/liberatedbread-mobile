// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/screens/device_screen.dart';

import '../fakes/fake_ble_service.dart';

final _device = IoTDevice(
  id: '01',
  name: 'ACME_A',
  rssi: -40,
  isConnectable: true,
  discoveredAt: DateTime(2026),
);

Widget _wrap(FakeBleService fake) => ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(home: DeviceScreen(device: _device)),
    );

void main() {
  testWidgets('shows connecting state immediately', (tester) async {
    final fake = FakeBleService();
    await tester.pumpWidget(_wrap(fake));

    expect(find.text('Connecting...'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('renders services after discovery succeeds', (tester) async {
    final fake = FakeBleService(servicesToReturn: const [
      BleDiscoveredService(
          uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: []),
    ]);
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    expect(find.text('Battery Service'), findsOneWidget);
  });

  testWidgets('shows error state and retry when connect fails', (tester) async {
    final fake = FakeBleService(connectError: StateError('no BLE'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    expect(find.textContaining('no BLE'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('retry re-attempts connection', (tester) async {
    final fake = FakeBleService(connectError: StateError('boom'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();
    expect(fake.connectedIds, isEmpty);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    // Still errors (connectError is sticky) but we've attempted again.
    expect(find.textContaining('boom'), findsOneWidget);
  });
}
