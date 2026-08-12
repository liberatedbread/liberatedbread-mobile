// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/screens/group_edit_screen.dart';
import 'package:liberated_bread_mobile/screens/groups_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences _prefs;

Map<String, Object> _seededDevices() => {
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB:CC:DD:EE:01',
          'name': 'ACME_Living_Room',
          'lastSeen': '2026-08-11T10:00:00.000',
          'category': 'light',
          'specKey': 'Example Smart Bulb|Acme Corp',
        },
        {
          'id': 'AA:BB:CC:DD:EE:02',
          'name': 'ACME_Bedroom',
          'lastSeen': '2026-08-11T09:00:00.000',
          'category': 'light',
          'specKey': 'Example Smart Bulb|Acme Corp',
        },
        {
          'id': 'AA:BB:CC:DD:EE:03',
          'name': 'Airthings Wave Plus',
          'lastSeen': '2026-08-11T08:00:00.000',
          'category': 'sensor',
          'specKey': 'Airthings Wave Family|Airthings ASA',
        },
        {
          'id': 'AA:BB:CC:DD:EE:04',
          'name': 'Old Mystery',
          'lastSeen': '2026-08-11T07:00:00.000',
        },
      ]),
    };

Widget _wrap({List<Override> overrides = const []}) => ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        // The guess path is exercised in provider tests; here it stays quiet
        // so the screen's buckets come from stored categories alone.
        scanGuessProvider.overrideWith((ref, identity) async => null),
        ...overrides,
      ],
      child: const MaterialApp(home: GroupsScreen()),
    );

void main() {
  testWidgets('empty saved list shows the empty state and no FAB',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('No groups yet'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('buckets saved devices into by-type groups', (tester) async {
    SharedPreferences.setMockInitialValues(_seededDevices());
    _prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('By type'), findsOneWidget);
    expect(find.text('Lights'), findsOneWidget);
    expect(find.text('2 devices'), findsOneWidget);
    expect(find.text('Sensors'), findsOneWidget);
    // The pre-feature record with no category is called out, not hidden.
    expect(find.text('Not identified yet'), findsOneWidget);
    expect(find.text('Old Mystery'), findsOneWidget);
  });

  testWidgets('lists custom groups with live member counts', (tester) async {
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB:CC:DD:EE:02',
          'name': 'ACME_Bedroom',
          'lastSeen': '2026-08-11T09:00:00.000',
          'category': 'light',
        },
        {
          'id': 'AA:BB:CC:DD:EE:05',
          'name': 'OBD Dongle',
          'lastSeen': '2026-08-11T06:00:00.000',
          'category': 'vehicle',
        },
      ]),
      'device_groups_v1': jsonEncode([
        {
          'id': 'g1',
          'name': 'Bedroom',
          // One live member, one forgotten id, and one whose recorded kind
          // turned out non-groupable — the count is what a run would touch.
          'deviceIds': [
            'AA:BB:CC:DD:EE:02',
            'GO:NE:00:00:00:00',
            'AA:BB:CC:DD:EE:05',
          ],
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('My groups'), findsOneWidget);
    // Neither the forgotten id nor the OBD dongle counts — only the live
    // groupable member does, matching what groupMembersProvider will run.
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text('Bedroom'), matching: find.byType(GroupTile)),
        matching: find.text('1 device'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the FAB opens the group editor', (tester) async {
    SharedPreferences.setMockInitialValues(_seededDevices());
    _prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('New group'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupEditScreen), findsOneWidget);
  });

  test('pluralLabel reads naturally', () {
    expect(DeviceCategory.light.pluralLabel, 'Lights');
    expect(DeviceCategory.switch_.pluralLabel, 'Switches');
    expect(DeviceCategory.climate.pluralLabel, 'Climate');
    expect(DeviceCategory.tv.pluralLabel, 'TVs');
  });
}
