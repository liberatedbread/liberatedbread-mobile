// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_group_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/screens/group_edit_screen.dart';
import 'package:liberated_bread_mobile/services/device_group_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences _prefs;

Map<String, Object> _saved() => {
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:01',
          'name': 'Bulb',
          'lastSeen': '2026-08-11T10:00:00.000',
          'category': 'light',
        },
        {
          'id': 'AA:02',
          'name': 'Wave',
          'lastSeen': '2026-08-11T09:00:00.000',
          'category': 'sensor',
        },
        {
          'id': 'AA:03',
          'name': 'Dongle',
          'lastSeen': '2026-08-11T08:00:00.000',
          'category': 'vehicle',
        },
      ]),
    };

Widget _wrap({DeviceGroup? group}) => ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(_prefs)],
      child: MaterialApp(home: GroupEditScreen(group: group)),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(_saved());
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('offers saved devices minus the non-groupable categories',
      (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();

    expect(find.text('Bulb'), findsOneWidget);
    expect(find.text('Wave'), findsOneWidget);
    // The OBD dongle is a serial bridge into a car, not a group member.
    expect(find.text('Dongle'), findsNothing);
  });

  testWidgets('creating a group needs a name and at least one member',
      (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();

    // Captured before saving: the save pops the screen off the navigator, so
    // its element is gone by the time there is a group to assert on.
    final container = ProviderScope.containerOf(
        tester.element(find.byType(GroupEditScreen)),
        listen: false);

    FilledButton saveButton() => tester.widget<FilledButton>(find.ancestor(
          of: find.text('Create group'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ));

    expect(saveButton().onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Living Room');
    await tester.pump();
    expect(saveButton().onPressed, isNull, reason: 'still no members picked');

    await tester.tap(find.text('Bulb'));
    await tester.pump();
    expect(saveButton().onPressed, isNotNull);

    await tester.tap(find.text('Create group'));
    await tester.pumpAndSettle();

    final group = container.read(deviceGroupsProvider).single;
    expect(group.name, 'Living Room');
    expect(group.deviceIds, ['AA:01']);
  });

  testWidgets('editing pre-fills and saves changes', (tester) async {
    SharedPreferences.setMockInitialValues({
      ..._saved(),
      'device_groups_v1': jsonEncode([
        {
          'id': 'g1',
          'name': 'Old name',
          'deviceIds': ['AA:01'],
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    const group = DeviceGroup(id: 'g1', name: 'Old name', deviceIds: ['AA:01']);
    await tester.pumpWidget(_wrap(group: group));
    await tester.pump();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(GroupEditScreen)),
        listen: false);

    expect(find.text('Old name'), findsOneWidget);
    final bulbRowCheckbox = tester.widget<Checkbox>(find.descendant(
      of: find.widgetWithText(InkWell, 'Bulb').first,
      matching: find.byType(Checkbox),
    ));
    expect(bulbRowCheckbox.value, isTrue);

    await tester.enterText(find.byType(TextField), 'New name');
    await tester.tap(find.text('Wave'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final updated = container.read(deviceGroupsProvider).single;
    expect(updated.name, 'New name');
    // Membership keeps the saved-devices (recency) order.
    expect(updated.deviceIds, ['AA:01', 'AA:02']);
  });

  testWidgets(
      'saving purges a member that became non-groupable while '
      'hidden from the checklist', (tester) async {
    // The Wave was in the group when it was unidentified; it has since
    // recorded a vehicle category, so the checklist no longer shows it —
    // saving must drop it rather than silently re-serialize the invisible id.
    SharedPreferences.setMockInitialValues({
      ..._saved(),
      'device_groups_v1': jsonEncode([
        {
          'id': 'g1',
          'name': 'Garage',
          'deviceIds': ['AA:01', 'AA:03'],
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    const group =
        DeviceGroup(id: 'g1', name: 'Garage', deviceIds: ['AA:01', 'AA:03']);
    await tester.pumpWidget(_wrap(group: group));
    await tester.pump();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(GroupEditScreen)),
        listen: false);

    expect(find.text('Dongle'), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(container.read(deviceGroupsProvider).single.deviceIds, ['AA:01']);
  });

  testWidgets('deleting asks first and keeps the devices', (tester) async {
    SharedPreferences.setMockInitialValues({
      ..._saved(),
      'device_groups_v1': jsonEncode([
        {
          'id': 'g1',
          'name': 'Doomed',
          'deviceIds': ['AA:01'],
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    const group = DeviceGroup(id: 'g1', name: 'Doomed', deviceIds: ['AA:01']);
    await tester.pumpWidget(_wrap(group: group));
    await tester.pump();

    final container = ProviderScope.containerOf(
        tester.element(find.byType(GroupEditScreen)),
        listen: false);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete "Doomed"?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(container.read(deviceGroupsProvider), isEmpty);
    // The saved devices themselves are untouched.
    expect(container.read(savedDevicesProvider), hasLength(3));
  });
}
