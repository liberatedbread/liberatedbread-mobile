// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/saved_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SavedDeviceStore> _store(
    [Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SavedDeviceStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seen = DateTime(2026, 8, 11, 10);

  test('empty store loads as an empty list', () async {
    final store = await _store();
    expect(store.load(), isEmpty);
  });

  test('category and specKey round-trip through save/load', () async {
    final store = await _store();
    await store.save(SavedDevice(
      id: 'AA:BB',
      name: 'ACME_Living_Room',
      lastSeen: seen,
      category: 'light',
      specKey: 'Example Smart Bulb|Acme Corp',
    ));

    final loaded = store.load().single;
    expect(loaded.id, 'AA:BB');
    expect(loaded.name, 'ACME_Living_Room');
    expect(loaded.category, 'light');
    expect(loaded.specKey, 'Example Smart Bulb|Acme Corp');
  });

  test('records saved before category/specKey existed load with nulls',
      () async {
    // A verbatim pre-feature record: only id/name/lastSeen.
    final store = await _store({
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB',
          'name': 'Old Device',
          'lastSeen': seen.toIso8601String(),
        },
      ]),
    });

    final loaded = store.load().single;
    expect(loaded.name, 'Old Device');
    expect(loaded.category, isNull);
    expect(loaded.specKey, isNull);
  });

  test('null fields are omitted from the stored json, not written as null',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SavedDeviceStore(prefs);
    await store.save(SavedDevice(id: 'AA:BB', name: 'Plain', lastSeen: seen));

    final raw = jsonDecode(prefs.getString('saved_devices_v1')!) as List;
    final record = raw.single as Map<String, dynamic>;
    expect(record.containsKey('category'), isFalse);
    expect(record.containsKey('specKey'), isFalse);
  });

  test('non-string or empty category/specKey load as null', () async {
    final store = await _store({
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB',
          'name': 'Odd',
          'lastSeen': seen.toIso8601String(),
          'category': 7,
          'specKey': '',
        },
      ]),
    });

    final loaded = store.load().single;
    expect(loaded.category, isNull);
    expect(loaded.specKey, isNull);
  });

  test('copyWith without arguments preserves category and specKey', () {
    final device = SavedDevice(
      id: 'AA:BB',
      name: 'Bulb',
      lastSeen: seen,
      category: 'light',
      specKey: 'Example Smart Bulb|Acme Corp',
    );

    final touched = device.copyWith(name: 'Bulb 2', lastSeen: seen);
    expect(touched.category, 'light');
    expect(touched.specKey, 'Example Smart Bulb|Acme Corp');
  });

  test('a corrupt blob loads as empty and bad records are skipped', () async {
    expect((await _store({'saved_devices_v1': 'not-json{'})).load(), isEmpty);

    final mixed = await _store({
      'saved_devices_v1': jsonEncode([
        {'id': '', 'name': 'no id', 'lastSeen': seen.toIso8601String()},
        {'id': 'OK:01', 'name': 'kept', 'lastSeen': seen.toIso8601String()},
        'not-a-map',
      ]),
    });
    expect(mixed.load().single.id, 'OK:01');
  });

  test('save keeps the list newest-first', () async {
    final store = await _store();
    await store.save(SavedDevice(
        id: 'A',
        name: 'older',
        lastSeen: seen.subtract(const Duration(days: 1))));
    await store.save(SavedDevice(id: 'B', name: 'newer', lastSeen: seen));

    expect([for (final d in store.load()) d.id], ['B', 'A']);
  });
}
