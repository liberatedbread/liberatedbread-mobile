// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/screens/ha_settings_screen.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ha_api_client.dart';
import '../fakes/in_memory_settings_store.dart';

/// Resolved in [setUp] so the scan screen can read saved devices synchronously
/// during build, the same way `main()` wires it in production.
late SharedPreferences _prefs;

Widget _wrap(FakeBleService fake) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
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
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('shows empty-state prompt before scanning', (tester) async {
    await tester.pumpWidget(_wrap(FakeBleService()));
    expect(find.text('Scan for BLE Devices'), findsOneWidget);
    // No results section until a scan has actually produced something.
    expect(find.text('Found'), findsNothing);
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
    expect(find.text('Found'), findsOneWidget);
    expect(find.text('2 devices found'), findsOneWidget);
  });

  testWidgets('History lists a previously paired device', (tester) async {
    // Seed a saved record the way a successful connect would have.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1':
          '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
    });
    _prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap(FakeBleService()));
    await tester.pumpAndSettle();

    expect(find.text('History'), findsOneWidget);
    expect(find.text('Probe One'), findsOneWidget);
  });

  testWidgets('forgetting a saved device removes it from History',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1':
          '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
    });
    _prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap(FakeBleService()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget Probe One'));
    await tester.pumpAndSettle();

    expect(find.text('Probe One'), findsNothing);
    expect(find.text('History'), findsNothing);
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

    // The user gets guidance, not the exception. 'Bad state:' is Dart's
    // rendering of a StateError and must never reach the screen.
    expect(find.textContaining('Scanning failed'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('settings gear opens the Home Assistant screen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        haApiClientProvider.overrideWithValue(FakeHaApiClient()),
      ],
      child: const MaterialApp(home: ScanScreen()),
    ));

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(HaSettingsScreen), findsOneWidget);
  });

  testWidgets('shows a distinct no-results state after an empty scan',
      (tester) async {
    // Never-scanned vs scanned-found-nothing must not be the same dead-end.
    final fake = FakeBleService();
    await tester.pumpWidget(_wrap(fake));

    // Before scanning: the generic prompt.
    expect(find.text('Scan for BLE Devices'), findsOneWidget);
    expect(find.text('No devices found'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // After an empty scan: the distinct guidance + rescan action.
    expect(find.text('No devices found'), findsOneWidget);
    expect(find.textContaining('Move closer'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
    expect(find.text('Scan for BLE Devices'), findsNothing);
  });

  testWidgets('permission denial shows specific guidance and open-settings',
      (tester) async {
    final fake =
        FakeBleService(scanError: const BlePermissionDeniedException());
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    // The open-settings action uses a settings icon, not the refresh default.
    final openSettingsButton =
        find.widgetWithText(ElevatedButton, 'Open settings');
    expect(openSettingsButton, findsOneWidget);
    expect(
      find.descendant(
          of: openSettingsButton, matching: find.byIcon(Icons.settings)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: openSettingsButton, matching: find.byIcon(Icons.refresh)),
      findsNothing,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('tapping a device stops the scan before navigating',
      (tester) async {
    final fake = FakeBleService(devicesToEmit: [_device('01', name: 'ACME_A')]);
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(fake.stopScanCount, 0);

    await tester.tap(find.text('ACME_A'));
    await tester.pump();

    // Scan is stopped before the device screen is pushed / connect begins.
    expect(fake.stopScanCount, greaterThan(0));

    await tester.pumpAndSettle();
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
