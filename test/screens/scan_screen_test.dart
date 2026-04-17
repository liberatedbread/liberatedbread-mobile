// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/screens/scan_screen.dart';

import '../fakes/fake_ble_service.dart';

Widget _wrap(FakeBleService fake) => ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: ScanScreen()),
    );

IoTDevice _device(String id,
    {String? name, int rssi = -40, bool connectable = true}) {
  return IoTDevice(
    id: id,
    name: name ?? 'dev-$id',
    rssi: rssi,
    isConnectable: connectable,
    discoveredAt: DateTime(2026),
  );
}

void main() {
  testWidgets('shows empty-state prompt before scanning', (tester) async {
    await tester.pumpWidget(_wrap(FakeBleService()));
    expect(find.text('Scan for BLE Devices'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('populates the list after scan', (tester) async {
    final fake = FakeBleService(devicesToEmit: [
      _device('01', name: 'ACME_A', rssi: -40),
      _device('02', name: 'ACME_B', rssi: -60),
    ]);
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('ACME_A'), findsOneWidget);
    expect(find.text('ACME_B'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(2));
  });

  testWidgets('FAB is disabled while scanning is in-flight', (tester) async {
    final fake = FakeBleService(
      devicesToEmit: [_device('01')],
      scanStepDelay: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 50));

    final fab =
        tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    expect(fab.onPressed, isNull);
    expect(find.text('Scanning...'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('renders error state when scan throws', (tester) async {
    final fake = FakeBleService(scanError: StateError('boom'));
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('boom'), findsOneWidget);
  });

  testWidgets('non-connectable device tile has no chevron', (tester) async {
    final fake = FakeBleService(devicesToEmit: [
      _device('01', name: 'nope', connectable: false),
    ]);
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });
}
