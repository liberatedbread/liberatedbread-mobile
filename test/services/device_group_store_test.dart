// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/device_group_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<DeviceGroupStore> _store(
    [Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return DeviceGroupStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('empty store loads as an empty list', () async {
    final store = await _store();
    expect(store.load(), isEmpty);
  });

  test('save/load round-trips a group', () async {
    final store = await _store();
    await store.save(const DeviceGroup(
      id: 'g1',
      name: 'Living Room',
      deviceIds: ['AA:BB', 'CC:DD'],
    ));

    final loaded = store.load().single;
    expect(loaded.id, 'g1');
    expect(loaded.name, 'Living Room');
    expect(loaded.deviceIds, ['AA:BB', 'CC:DD']);
  });

  test('updating a group keeps its place; new groups append', () async {
    final store = await _store();
    await store.save(const DeviceGroup(id: 'g1', name: 'First', deviceIds: []));
    await store
        .save(const DeviceGroup(id: 'g2', name: 'Second', deviceIds: []));
    await store.save(const DeviceGroup(
        id: 'g1', name: 'First renamed', deviceIds: ['AA:BB']));

    final loaded = store.load();
    expect([for (final g in loaded) g.id], ['g1', 'g2']);
    expect(loaded.first.name, 'First renamed');
    expect(loaded.first.deviceIds, ['AA:BB']);
  });

  test('remove forgets one group and keeps the rest', () async {
    final store = await _store();
    await store.save(const DeviceGroup(id: 'g1', name: 'A', deviceIds: []));
    await store.save(const DeviceGroup(id: 'g2', name: 'B', deviceIds: []));
    await store.remove('g1');

    expect(store.load().single.id, 'g2');
  });

  test('a corrupt blob loads as empty instead of throwing at startup',
      () async {
    final store = await _store({'device_groups_v1': 'not-json{'});
    expect(store.load(), isEmpty);
  });

  test('bad records and non-string member ids are skipped', () async {
    final store = await _store({
      'device_groups_v1': jsonEncode([
        {'id': 'g1', 'name': '', 'deviceIds': []}, // empty name
        {'id': 'g2', 'name': 'no members key'}, // deviceIds missing
        {
          'id': 'g3',
          'name': 'kept',
          'deviceIds': ['AA:BB', 7, '', 'CC:DD'],
        },
        'not-a-map',
      ]),
    });

    final loaded = store.load().single;
    expect(loaded.id, 'g3');
    expect(loaded.deviceIds, ['AA:BB', 'CC:DD']);
  });

  test('non-list json loads as empty', () async {
    final store = await _store({
      'device_groups_v1': jsonEncode({'id': 'g1'}),
    });
    expect(store.load(), isEmpty);
  });
}
