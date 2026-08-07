// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// End-to-end walkthrough of the mock flow: scan → connect → discover →
// read a characteristic. Runs against MockBleService (no real BLE).
// Launch via:
//   flutter test integration_test/mock_flow_test.dart \
//     --dart-define=LIBERATED_BREAD_MOCK=true
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/mock_ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scan → connect → discover services', (tester) async {
    // The app's main() resolves SharedPreferences and overrides the provider
    // before runApp; pumping LiberatedBreadApp directly bypasses that, and
    // ScanScreen's History section (savedDevicesProvider) needs it on first
    // build.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          bleServiceProvider.overrideWithValue(MockBleService()),
        ],
        child: const LiberatedBreadApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Start scan from the FAB.
    await tester.tap(find.byType(FloatingActionButton));
    // Mock service emits a device every ~400ms; allow enough settle time.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(seconds: 6));

    expect(find.text('ACME_Living_Room'), findsOneWidget);
    expect(find.text('ACME_Bedroom'), findsOneWidget);

    // Navigate into the first device.
    await tester.tap(find.text('ACME_Living_Room'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // After connect + discover, services render.
    expect(find.text('Battery Service'), findsOneWidget);
  });
}
