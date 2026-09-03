// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/screens/groups_screen.dart';
import 'package:liberated_bread_mobile/screens/home_shell.dart';
import 'package:liberated_bread_mobile/screens/saved_devices_screen.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/screens/terms_screen.dart';

import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_ble_service.dart';

late SharedPreferences _prefs;

void main() {
  setUp(() async {
    // Seed the disclaimer as already accepted so these tests exercise the app
    // proper; the first-launch gate has its own test below that starts empty.
    SharedPreferences.setMockInitialValues(
        {AppConstants.termsAcceptedKey: AppConstants.termsVersion});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets(
      'first launch shows the disclaimer gate, and accepting it opens '
      'the app', (tester) async {
    // A tall viewport so the disclaimer's accept button is on-screen (the gate
    // is a long ListView).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const LiberatedBreadApp(),
    ));
    await tester.pump();

    // The gate is up; the app proper is not yet reachable.
    expect(find.byType(TermsScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    // The disclaimer heading. Asserted on 'unofficial' rather than on the
    // word it used to carry: the gate deliberately no longer says
    // "experimental" or "beta", because Guideline 2.2 rejects demos and betas
    // and a reviewer reads this screen first. The disclaimer CONTENT is the
    // point and is unchanged; only the framing moved.
    expect(find.textContaining('unofficial'), findsOneWidget);

    await tester.ensureVisible(find.text('I understand and agree'));
    await tester.tap(find.text('I understand and agree'));
    await tester.pumpAndSettle();

    // Accepting records the version and reveals the app.
    expect(find.byType(TermsScreen), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
    expect(_prefs.getInt(AppConstants.termsAcceptedKey),
        AppConstants.termsVersion);
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
    expect(find.text('Groups'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
  });

  testWidgets('every Hero tag in the shell is unique', (tester) async {
    // HomeShell holds all three tabs alive in an IndexedStack, so every tab's
    // Heroes are in the tree at the same time — including two FloatingActionButtons
    // that would otherwise share the default tag. A collision is not cosmetic:
    // the hero controller throws on the next route push, which is every tap on
    // a device, and it throws from a scheduler callback where the stack trace
    // points at Flutter rather than at the two widgets involved.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const LiberatedBreadApp(),
    ));
    await tester.pump();

    final tags = tester
        .widgetList<Hero>(find.byType(Hero, skipOffstage: false))
        .map((h) => h.tag.toString())
        .toList();
    expect(
      tags.toSet(),
      hasLength(tags.length),
      reason: 'Heroes alive together in the shell must have distinct tags; '
          'found $tags',
    );
  });

  testWidgets('switching tabs stops the BLE scan, and coming back restarts it',
      (tester) async {
    // The shell keeps every tab alive so a scan survives a glance elsewhere —
    // but alive is not the same as working. A continuous scan running behind
    // the Saved tab is the radio spending battery on a list that is three
    // layers deep in an IndexedStack.
    final fake = FakeBleService(
      devicesToEmit: [
        IoTDevice(
          id: 'AA:BB:CC:DD:EE:01',
          name: 'ACME_A',
          rssi: -40,
          isConnectable: true,
          discoveredAt: DateTime.now(),
        ),
      ],
      // Holds the fake's scan open past the deferred stop, the way the real
      // continuous scan stays open.
      scanHold: Completer<void>(),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const LiberatedBreadApp(),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.scanTimeouts, hasLength(1),
        reason: 'Nearby is the landing tab, so it scans on launch');

    await tester.tap(find.text('Saved'));
    // One pump to build the switched tab (arming the deferred stop), then
    // past the couple-of-seconds grace that keeps a mere glance from cycling
    // the radio.
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(fake.stopScanCount, greaterThan(0));

    await tester.tap(find.text('Nearby'));
    // Bounded pumps, not pumpAndSettle: the resumed scan keeps the radar
    // animation live, so there is no settled frame to wait for.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.scanTimeouts, hasLength(2));
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

    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupsScreen), findsOneWidget);
    expect(find.text('No groups yet'), findsOneWidget);
  });
}
