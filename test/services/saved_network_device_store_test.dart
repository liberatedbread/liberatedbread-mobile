// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/saved_network_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SavedNetworkDeviceStore> _store(
    [Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SavedNetworkDeviceStore(await SharedPreferences.getInstance());
}

NetworkDevice _sighting({
  String host = '192.168.1.20',
  String name = 'Living Room TV',
  String? hostname,
  Map<String, String> txt = const {},
}) =>
    NetworkDevice(
      host: host,
      name: name,
      hostname: hostname,
      port: 8060,
      ssdpPort: 8060,
      ssdpDescriptionPath: '/',
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime(2026, 1, 1),
      txt: txt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('save/load round-trips every field', () async {
    final store = await _store();
    await store.save(SavedNetworkDevice(
      id: 'hn:tv.local',
      name: 'Living Room TV',
      lastSeen: DateTime(2026, 2, 3),
      host: '192.168.1.20',
      hostname: 'tv.local',
      port: 8060,
      ssdpPort: 8060,
      ssdpDescriptionPath: '/',
      ssdpTargets: const ['roku:ecp'],
      category: 'tv',
      specKey: 'Roku External Control Protocol|Roku',
    ));

    final loaded = store.load().single;
    expect(loaded.id, 'hn:tv.local');
    expect(loaded.name, 'Living Room TV');
    expect(loaded.lastSeen, DateTime(2026, 2, 3));
    expect(loaded.host, '192.168.1.20');
    expect(loaded.hostname, 'tv.local');
    expect(loaded.port, 8060);
    expect(loaded.ssdpPort, 8060);
    expect(loaded.ssdpDescriptionPath, '/');
    expect(loaded.ssdpTargets, ['roku:ecp']);
    expect(loaded.category, 'tv');
    expect(loaded.specKey, 'Roku External Control Protocol|Roku');
  });

  test('loads newest-first and re-saving an id replaces the record', () async {
    final store = await _store();
    await store.save(SavedNetworkDevice(
        id: 'a', name: 'Old', lastSeen: DateTime(2026, 1, 1), host: '1.1.1.1'));
    await store.save(SavedNetworkDevice(
        id: 'b', name: 'New', lastSeen: DateTime(2026, 1, 2), host: '2.2.2.2'));
    await store.save(SavedNetworkDevice(
        id: 'a',
        name: 'Old, moved',
        lastSeen: DateTime(2026, 1, 3),
        host: '3.3.3.3'));

    final loaded = store.load();
    expect([for (final d in loaded) d.id], ['a', 'b']);
    expect(loaded.first.name, 'Old, moved');
    expect(loaded.first.host, '3.3.3.3');
    expect(store.load(), hasLength(2));
  });

  test('a corrupt record is dropped without taking the list down', () async {
    final store = await _store({
      'saved_network_devices_v1': jsonEncode([
        {'id': '', 'name': 'no id', 'host': '1.1.1.1'},
        {'id': 'ok', 'name': 'kept', 'host': '2.2.2.2'},
        {'id': 'no-host', 'name': 'dropped'},
      ]),
    });
    expect([for (final d in store.load()) d.id], ['ok']);
  });

  test('remove deletes by id', () async {
    final store = await _store();
    await store.save(SavedNetworkDevice(
        id: 'a', name: 'A', lastSeen: DateTime(2026, 1, 1), host: '1.1.1.1'));
    await store.remove('a');
    expect(store.load(), isEmpty);
  });

  group('stableIdFor prefers', () {
    test('the advertised MAC above everything', () {
      final id = SavedNetworkDevice.stableIdFor(_sighting(
        hostname: 'tv.local',
        txt: const {'mac': 'aa:bb:cc:dd:ee:ff'},
      ));
      expect(id, startsWith('mac:'));
    });

    test('the hostname when no MAC is published', () {
      expect(SavedNetworkDevice.stableIdFor(_sighting(hostname: 'tv.local')),
          'hn:tv.local');
    });

    test('the advertised name when there is no hostname either', () {
      expect(
          SavedNetworkDevice.stableIdFor(_sighting()), 'name:Living Room TV');
    });

    test('the address only as a last resort', () {
      expect(SavedNetworkDevice.stableIdFor(_sighting(name: '')),
          'host:192.168.1.20');
    });
  });

  test('toNetworkDevice rebuilds a sighting the control screen can open', () {
    final device = SavedNetworkDevice(
      id: 'hn:tv.local',
      name: 'Living Room TV',
      lastSeen: DateTime(2026, 2, 3),
      host: '192.168.1.20',
      hostname: 'tv.local',
      port: 8060,
      ssdpPort: 8060,
      ssdpDescriptionPath: '/',
      ssdpTargets: const ['roku:ecp'],
    ).toNetworkDevice();
    expect(device.host, '192.168.1.20');
    expect(device.controlPort, 8060);
    expect(device.ssdpTargets, ['roku:ecp']);
    expect(device.sources, {NetworkDiscoverySource.ssdp});
  });
}
