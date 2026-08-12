// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// End-to-end walkthrough of a group operation: two saved bulbs → Groups tab →
// the automatic "Lights" group → Turn all off → both members report done,
// one connection at a time. Runs against MockBleService (no real BLE) with
// the REAL Rust codec: the members' spec resolution, the command encoding and
// the mock's spec-derived GATT tree all go through the bridge, so this covers
// the whole group pipeline short of a radio.
//
// Launch via:
//   flutter test integration_test/group_flow_test.dart \
//     --dart-define=LIBERATED_BREAD_MOCK=true
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/mock_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/frb_generated.dart'
    show RustLib;
import 'package:shared_preferences/shared_preferences.dart';

/// Pump frames until [finder] matches at least [count] widgets. Same shape
/// (and same reasoning) as mock_flow_test.dart's `_pumpUntil`: never
/// `pumpAndSettle`, because the scan tab keeps animating behind the shell and
/// there is no settled frame to wait for.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int count = 1,
  Duration timeout = const Duration(seconds: 20),
}) async {
  const step = Duration(milliseconds: 100);
  for (var waited = Duration.zero; waited < timeout; waited += step) {
    await tester.pump(step);
    if (finder.evaluate().length >= count) return;
  }
  fail('timed out after $timeout waiting for $count × $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('turn all lights off drives every member of the group',
      (tester) async {
    // Standalone (the linux-desktop per-file job) this suite brings the
    // bridge up itself; in ci_all_test.dart it is grouped after the suites
    // that already did. The real codec is the point — see the header.
    if (!MockBleService.rustAvailable) {
      await RustLib.init();
    }

    // Two bulbs saved from a previous session, category and spec match
    // already recorded — the state a user who has connected to each bulb
    // once actually has.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1': jsonEncode([
        for (final (id, name) in [
          ('AA:BB:CC:DD:EE:01', 'ACME_Living_Room'),
          ('AA:BB:CC:DD:EE:02', 'ACME_Bedroom'),
        ])
          {
            'id': id,
            'name': name,
            'lastSeen': '2026-08-11T10:00:00.000',
            'category': 'light',
            'specKey': 'Example Smart Bulb|Acme Corp',
          },
      ]),
    });
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

    // The saved categories alone put both bulbs in an automatic Lights group.
    await _pumpUntil(tester, find.text('Groups'));
    await tester.tap(find.text('Groups'));
    await _pumpUntil(tester, find.text('Lights'));
    await _pumpUntil(tester, find.text('2 devices'));

    await tester.tap(find.text('Lights'));
    // Member rows appear once the catalogue parse resolves each specKey back
    // to the vendored example-bulb spec.
    await _pumpUntil(tester, find.text('ACME_Living_Room'));
    await _pumpUntil(tester, find.text('ACME_Bedroom'));

    await tester.tap(find.text('Turn all off'));

    // Both members end ok — the runner connected, encoded power_off through
    // the real codec, wrote it to the mock, and disconnected, sequentially.
    // The mock cannot refuse a write, so 'ok' here proves the whole resolve →
    // encode → write path held together; outcomes are the assertion, not
    // read-back (the mock's status characteristic is last-write-wins per
    // UUID, not a device simulation that flips state on commands).
    await _pumpUntil(tester, find.text('1 command sent'), count: 2);
    expect(find.text('1 command sent'), findsNWidgets(2));
  });
}
