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

/// Pump frames until [finder] matches, then stop. Fails at [timeout].
///
/// Deliberately not `pumpAndSettle`. This app legitimately never goes idle on
/// the screens this test drives — the scan spinner animates and the device
/// screen polls its notify characteristic every two seconds — so there is no
/// settled frame to wait for and `pumpAndSettle` runs until its timeout throws.
/// `e2e_walkthrough_test.dart` already says exactly this above its own `_soak`
/// helper.
///
/// What hid it is that `pumpAndSettle`'s first positional argument is the pump
/// INTERVAL, not a timeout — the timeout is a third argument defaulting to ten
/// minutes. So `pumpAndSettle(Duration(seconds: 6))` reads like "give it six
/// seconds" and means "step six seconds per frame, for up to ten minutes". Two
/// of those in this test is twenty minutes of silence: `flutter test` prints
/// nothing while a test body runs, so the iOS and Android jobs sat with no
/// output until the runner killed them.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  const step = Duration(milliseconds: 100);
  for (var waited = Duration.zero; waited < timeout; waited += step) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('timed out after $timeout waiting for $finder');
}

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
    // The shell before a scan starts does settle, and this is the one place the
    // test wants it to — the app must be fully built before the FAB is tapped.
    // Bounded anyway: an idle animation appearing here later should fail the
    // test in seconds, not stall the job for ten minutes.
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 30),
    );

    // Start scan from the FAB. The mock emits a device every ~400ms.
    await tester.tap(find.byType(FloatingActionButton));
    await _pumpUntil(tester, find.text('ACME_Living_Room'));
    await _pumpUntil(tester, find.text('ACME_Bedroom'));

    // Navigate into the first device: connect, then discover.
    await tester.tap(find.text('ACME_Living_Room'));
    await _pumpUntil(tester, find.text('Battery Service'));
    expect(find.text('Battery Service'), findsOneWidget);
  });
}
