// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/screens/home_shell.dart';
import 'package:liberated_bread_mobile/screens/saved_devices_screen.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';

import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_ble_service.dart';

late SharedPreferences _prefs;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('app builds and opens on the scan screen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const LiberatedBreadApp(),
    ));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
    // Nearby is the landing tab: scanning is what someone opens the app to do.
    expect(find.text('Nearby'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
  });

  testWidgets('the bottom bar switches destination', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const LiberatedBreadApp(),
    ));
    await tester.pump();

    await tester.tap(find.text('Saved'));
    await tester.pumpAndSettle();

    expect(find.byType(SavedDevicesScreen), findsOneWidget);
    expect(find.text('No saved devices yet'), findsOneWidget);
  });
}
