// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The app on Linux, over the real BLE path, against a virtual BlueZ stack.
//
// On Linux the real path is flutter_blue_plus_linux, which does not talk to a
// radio — it talks to BlueZ's `org.bluez` D-Bus service. scripts/
// ble_virtual_peripheral.py IS that service for the duration of this test:
// emulated peripherals served on a private bus, no radio, no kernel module, no
// root. scripts/linux-virtual-ble.sh does the wiring and must be what launches
// this file:
//
//   ./scripts/linux-virtual-ble.sh xvfb-run -a flutter test \
//       integration_test/linux_virtual_ble_test.dart -d linux --tags=bluez
//
// WHAT THIS COVERS THAT test/app_real_ble_path_test.dart DOES NOT
//
// That suite substitutes flutter_blue_plus's platform interface, so everything
// above that line is exercised and nothing below it. Here the Linux backend
// itself runs: BlueZ's object tree becomes a GATT tree, D-Bus property changes
// become notifications, and D-Bus error NAMES stand in for the ATT codes every
// other platform reports — "Not paired" instead of 0x05, which is the one
// branch of isPairingRequiredError no other test can reach.
//
// The file is tagged so scripts/ci-linux-tests.sh's ordinary loop skips it:
// without the wrapper there is no org.bluez to talk to, and the failure would
// look like an app bug rather than a missing harness.
@Tags(['bluez'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pump until [finder] matches or the deadline passes.
///
/// Deliberately not `pumpAndSettle`: the app is talking to another process over
/// D-Bus here, and there is no frame-count at which that has definitely
/// answered.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  // bleServiceProvider is overridden explicitly rather than left to the
  // compile-time flag: the Linux job builds every integration suite with
  // --dart-define=LIBERATED_BREAD_MOCK=true so they share one warm build cache,
  // and a different define here would force a full rebuild inside the load
  // phase's hardcoded 12-minute cap. The override says what this file wants
  // without disturbing that.
  Widget app() => ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          bleServiceProvider.overrideWithValue(RealBleService()),
        ],
        child: const LiberatedBreadApp(),
      );

  testWidgets('scans and connects through BlueZ, and reads a characteristic',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byType(FloatingActionButton));
    await pumpUntil(tester, find.text('ACME_Living_Room'));
    expect(find.text('ACME_Living_Room'), findsOneWidget,
        reason: 'BlueZ discovery should surface the virtual peripheral');

    await tester.tap(find.text('ACME_Living_Room'));
    await pumpUntil(tester, find.text('Battery Service'));

    // The GATT tree came from BlueZ's D-Bus object tree, through
    // flutter_blue_plus_linux, through RealBleService. Naming the service means
    // the UUID survived that round trip in a form the app recognizes.
    expect(find.text('Battery Service'), findsOneWidget);

    // 0x55 is 85, the battery level the virtual peripheral holds.
    await pumpUntil(tester, find.textContaining('55'));
    expect(find.textContaining('55'), findsWidgets,
        reason: 'a real read crossed D-Bus and came back');
  });

  testWidgets('a BlueZ device that is not paired asks the user to pair',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byType(FloatingActionButton));
    await pumpUntil(tester, find.text('Vault Sensor'));
    await tester.tap(find.text('Vault Sensor'));

    // BlueZ reports the refusal as the D-Bus error name
    // org.bluez.Error.NotPermitted with the message "Not paired" — no ATT code
    // anywhere. This is the description-string branch of
    // isPairingRequiredError, and this is the only place it runs for real.
    await pumpUntil(tester, find.textContaining('needs to be paired'));
    expect(find.textContaining('needs to be paired'), findsWidgets);
    expect(find.textContaining('NotPermitted'), findsNothing,
        reason: 'the D-Bus error name is for the log, not the screen');
  });
}
