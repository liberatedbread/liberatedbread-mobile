// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/providers/radio_profile_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/in_memory_settings_store.dart';

Future<void> _pump(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  Map<String, String> settings = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPrefs = await SharedPreferences.getInstance();
  final store = InMemorySettingsStore({...settings});

  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPrefs),
      prefsSettingsStoreProvider.overrideWith((ref) async => store),
      settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
    ],
    child: const MaterialApp(home: RadioScreen()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the selected radio and what can be done with it',
      (tester) async {
    await _pump(tester);
    expect(find.text('Radio'), findsWidgets);
    expect(find.text(defaultRadioProfile.displayName), findsOneWidget);
    expect(find.text('Suggest channels near me'), findsOneWidget);
  });

  testWidgets('says there are no plans yet, and how to get one',
      (tester) async {
    await _pump(tester);
    expect(find.textContaining('No channel plans yet'), findsOneWidget);
  });

  testWidgets('lists stored plans with their channel counts', (tester) async {
    await _pump(tester, prefs: {
      'radio_channel_plans_v1': jsonEncode([
        {
          'id': 'p1',
          'name': 'Local repeaters',
          'radioProfileId': 'uv-5r-mini',
          'channels': [
            {'name': 'A', 'rx': 146940000, 'tx': 146340000},
            {'name': 'B', 'rx': 146520000, 'tx': 146520000},
          ],
          'createdAt': '2026-08-01T00:00:00.000Z',
          'modifiedAt': '2026-08-02T00:00:00.000Z',
        }
      ]),
    });
    expect(find.text('Local repeaters'), findsOneWidget);
    expect(find.textContaining('2 channels'), findsOneWidget);
    expect(find.textContaining('No channel plans yet'), findsNothing);
  });

  testWidgets('flags a plan built with the transmit range widened',
      (tester) async {
    await _pump(tester, prefs: {
      'radio_channel_plans_v1': jsonEncode([
        {
          'id': 'p1',
          'name': 'MARS',
          'radioProfileId': 'uv-5r-mini',
          'channels': <Object>[],
          'builtWithTxUnlock': true,
          'createdAt': '2026-08-01T00:00:00.000Z',
          'modifiedAt': '2026-08-01T00:00:00.000Z',
        }
      ]),
    });
    expect(find.textContaining('widened transmit range'), findsOneWidget);
  });

  testWidgets('the picker says what this build can do with each radio',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.text(defaultRadioProfile.displayName));
    await tester.pumpAndSettle();

    expect(find.textContaining('programs over Bluetooth'), findsWidgets);
    expect(find.textContaining('export to CHIRP'), findsWidgets);
    // The UV-32 is same-family inference, and says so before it is picked.
    expect(find.textContaining('unconfirmed on this model'), findsWidgets);
  });

  testWidgets('picking a radio persists the choice', (tester) async {
    final store = InMemorySettingsStore();
    SharedPreferences.setMockInitialValues({});
    final sharedPrefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPrefs),
        prefsSettingsStoreProvider.overrideWith((ref) async => store),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
      ],
      child: const MaterialApp(home: RadioScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text(defaultRadioProfile.displayName));
    await tester.pumpAndSettle();
    // The first entry in the catalogue, which is not the default and sits
    // above the fold in an 800x600 test window.
    await tester.tap(find.text(uv5rProfile.displayName).last);
    await tester.pumpAndSettle();

    expect(store.values[SelectedRadioProfileNotifier.key], uv5rProfile.id);
  });

  group('the transmit-range switch', () {
    testWidgets('is hidden for a radio whose family has no band limits',
        (tester) async {
      // The default radio is a Mini, and the whole UV-17Pro family stores its
      // transmit range in firmware. Offering a switch that could not do
      // anything would be worse than not offering one.
      expect(defaultRadioProfile.txUnlock.supported, isFalse);
      await _pump(tester);
      expect(find.text('Widen transmit range'), findsNothing);
    });

    testWidgets('appears once a radio that can be widened is selected',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text(defaultRadioProfile.displayName));
      await tester.pumpAndSettle();
      await tester.tap(find.text(uv5rProfile.displayName).last);
      await tester.pumpAndSettle();

      expect(find.text('Widen transmit range'), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Widen transmit range'));
      expect(tile.value, isFalse);
      expect(find.textContaining('as it left the factory'), findsOneWidget);
    });

    testWidgets('turning it on opens the acknowledgement first',
        (tester) async {
      await _pump(tester, settings: {
        SelectedRadioProfileNotifier.key: uv5rProfile.id,
      });
      await tester
          .tap(find.widgetWithText(SwitchListTile, 'Widen transmit range'));
      await tester.pumpAndSettle();

      expect(find.text('Widen the transmit range?'), findsOneWidget);
    });

    testWidgets('cancelling the acknowledgement leaves it off', (tester) async {
      final store = InMemorySettingsStore(
          {SelectedRadioProfileNotifier.key: uv5rProfile.id});
      SharedPreferences.setMockInitialValues({});
      final sharedPrefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sharedPrefs),
          prefsSettingsStoreProvider.overrideWith((ref) async => store),
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ],
        child: const MaterialApp(home: RadioScreen()),
      ));
      await tester.pumpAndSettle();

      await tester
          .tap(find.widgetWithText(SwitchListTile, 'Widen transmit range'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      final tile = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Widen transmit range'));
      expect(tile.value, isFalse);
      expect(store.values.containsKey(TxUnlockNotifier.key), isFalse);
    });

    testWidgets('confirming turns it on and persists it', (tester) async {
      final store = InMemorySettingsStore(
          {SelectedRadioProfileNotifier.key: uv5rProfile.id});
      SharedPreferences.setMockInitialValues({});
      final sharedPrefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sharedPrefs),
          prefsSettingsStoreProvider.overrideWith((ref) async => store),
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ],
        child: const MaterialApp(home: RadioScreen()),
      ));
      await tester.pumpAndSettle();

      await tester
          .tap(find.widgetWithText(SwitchListTile, 'Widen transmit range'));
      await tester.pumpAndSettle();

      final checkbox = find.byType(CheckboxListTile);
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
      await tester.pumpAndSettle();

      expect(store.values[TxUnlockNotifier.key], contains(uv5rProfile.id));
      expect(find.textContaining('On for this radio'), findsOneWidget);
    });
  });

  testWidgets('a new plan can be created and named', (tester) async {
    await _pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'New'));
    await tester.pumpAndSettle();

    expect(find.text('Plan name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Weekend');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Straight into the new plan's editor.
    expect(find.text('Weekend'), findsWidgets);
  });
}
