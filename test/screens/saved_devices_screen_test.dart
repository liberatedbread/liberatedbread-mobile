// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/screens/saved_devices_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';

late SharedPreferences _prefs;

Widget _wrap() => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const MaterialApp(home: SavedDevicesScreen()),
    );

Future<void> _seed(String json) async {
  SharedPreferences.setMockInitialValues({'saved_devices_v1': json});
  _prefs = await SharedPreferences.getInstance();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('an empty pane explains how devices get here', (tester) async {
    // The pane is reachable from the bottom bar before anything is paired, so
    // it has to say something more useful than being blank.
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('No saved devices yet'), findsOneWidget);
    expect(find.textContaining('Nearby tab'), findsOneWidget);
  });

  testWidgets('lists a previously paired device', (tester) async {
    await _seed(
        '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]');

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Paired'), findsWidgets);
    expect(find.text('Probe One'), findsOneWidget);
  });

  testWidgets('forgetting a device removes it and says so', (tester) async {
    await _seed(
        '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]');

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget Probe One'));
    await tester.pumpAndSettle();

    expect(find.text('Probe One'), findsNothing);
    expect(find.text('Removed Probe One'), findsOneWidget);
    expect(find.text('No saved devices yet'), findsOneWidget);
  });

  testWidgets('a device saved without a name still has a title',
      (tester) async {
    await _seed('[{"id":"aa","name":"","lastSeen":"2026-07-30T12:00:00.000"}]');

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Unknown device'), findsOneWidget);
  });

  group('relativeTime', () {
    test('reads as a relative time until that stops being useful', () {
      final now = DateTime.now();
      expect(relativeTime(now), 'Just now');
      expect(relativeTime(now.subtract(const Duration(minutes: 5))), '5m ago');
      expect(relativeTime(now.subtract(const Duration(hours: 3))), '3h ago');
      expect(relativeTime(now.subtract(const Duration(days: 2))), '2d ago');
      // Past a week "42d ago" tells you less than a date does.
      expect(relativeTime(DateTime(2026, 1, 2)), '2026-01-02');
    });
  });
}
