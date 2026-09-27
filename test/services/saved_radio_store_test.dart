// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';
import 'package:liberated_bread_mobile/services/saved_radio_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SavedRadioStore> _store([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SavedRadioStore(await SharedPreferences.getInstance());
}

SavedRadio _radio({
  RadioTransport transport = RadioTransport.ble,
  String id = 'AA:BB',
  String name = 'UV-5R Mini',
  DateTime? lastSeen,
  String? profileId,
}) => SavedRadio(
  transport: transport,
  id: id,
  name: name,
  lastSeen: lastSeen ?? DateTime(2026, 9, 1),
  radioProfileId: profileId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an empty store loads as an empty list', () async {
    expect((await _store()).load(), isEmpty);
  });

  test('every field round-trips', () async {
    final store = await _store();
    await store.save(
      _radio(
        transport: RadioTransport.usb,
        id: '/dev/ttyUSB0',
        name: 'Truck radio',
        lastSeen: DateTime(2026, 9, 2, 8, 30),
        profileId: 'uv5r',
      ),
    );

    final loaded = store.load().single;
    expect(loaded.transport, RadioTransport.usb);
    expect(loaded.id, '/dev/ttyUSB0');
    expect(loaded.name, 'Truck radio');
    expect(loaded.lastSeen, DateTime(2026, 9, 2, 8, 30));
    expect(loaded.radioProfileId, 'uv5r');
    expect(
      loaded.target,
      const RadioTarget(
        transport: RadioTransport.usb,
        id: '/dev/ttyUSB0',
        name: '',
      ),
    );
  });

  test('saving again replaces rather than duplicates', () async {
    final store = await _store();
    await store.save(_radio(name: 'Old name'));
    await store.save(_radio(name: 'New name'));
    expect(store.load().single.name, 'New name');
  });

  test('the same id over two transports is two radios', () async {
    final store = await _store();
    await store.save(_radio(transport: RadioTransport.ble, id: 'X'));
    await store.save(_radio(transport: RadioTransport.usb, id: 'X'));
    expect(store.load(), hasLength(2));
  });

  test('loads newest first', () async {
    final store = await _store();
    await store.save(_radio(id: 'old', lastSeen: DateTime(2026, 1, 1)));
    await store.save(_radio(id: 'new', lastSeen: DateTime(2026, 9, 1)));
    await store.save(_radio(id: 'mid', lastSeen: DateTime(2026, 5, 1)));
    expect([for (final r in store.load()) r.id], ['new', 'mid', 'old']);
  });

  test('remove forgets exactly one radio', () async {
    final store = await _store();
    await store.save(_radio(transport: RadioTransport.ble, id: 'X'));
    await store.save(_radio(transport: RadioTransport.usb, id: 'X'));
    await store.remove(
      const RadioTarget(transport: RadioTransport.usb, id: 'X', name: ''),
    );
    final left = store.load().single;
    expect(left.transport, RadioTransport.ble);
  });

  test('one corrupt record does not take the list down with it', () async {
    final store = await _store({
      'saved_radios_v1': jsonEncode([
        {'transport': 'ble', 'id': 'good', 'name': 'Fine'},
        {'transport': 'carrier-pigeon', 'id': 'bad', 'name': 'Unknown link'},
        {'transport': 'usb', 'id': '', 'name': 'No id'},
        {'transport': 'usb', 'name': 'Missing id'},
        'not even an object',
      ]),
    });
    final loaded = store.load();
    expect([for (final r in loaded) r.id], ['good']);
    expect(
      loaded.single.lastSeen,
      DateTime.fromMillisecondsSinceEpoch(0),
      reason: 'a missing timestamp sorts last rather than failing the row',
    );
  });

  test('an empty profile id reads as none', () async {
    final store = await _store({
      'saved_radios_v1': jsonEncode([
        {'transport': 'ble', 'id': 'a', 'name': 'A', 'radioProfileId': ''},
      ]),
    });
    expect(store.load().single.radioProfileId, isNull);
  });
}
