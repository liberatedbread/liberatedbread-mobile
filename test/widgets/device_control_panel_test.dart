// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/widgets/device_control_panel.dart';

import '../fakes/fake_ble_service.dart';

Widget _wrap(Widget child, FakeBleService fake) => ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('empty services renders the empty message', (tester) async {
    await tester.pumpWidget(_wrap(
      const DeviceControlPanel(deviceId: '01', services: []),
      FakeBleService(),
    ));
    expect(find.text('No services found on this device.'), findsOneWidget);
  });

  testWidgets('renders one card per service with well-known names',
      (tester) async {
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
      const DeviceControlPanel(deviceId: '01', services: services),
      FakeBleService(),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('Battery Service'), findsOneWidget);
    expect(find.text('Generic Access'), findsOneWidget);
  });
}
