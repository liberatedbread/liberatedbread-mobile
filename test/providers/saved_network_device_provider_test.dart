// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/device_group_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_network_device_provider.dart';
import 'package:liberated_bread_mobile/services/device_group_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

NetworkDevice _sighting({String host = '192.168.1.20'}) => NetworkDevice(
      host: host,
      name: 'Living Room TV',
      hostname: 'tv.local',
      port: 8060,
      ssdpPort: 8060,
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    return c;
  }

  test('touch saves a sighting with its match, and refreshes the cache',
      () async {
    final c = await container();
    final notifier = c.read(savedNetworkDevicesProvider.notifier);

    await notifier.touch(_sighting(),
        category: 'tv', specKey: 'Roku External Control Protocol|Roku');
    var saved = c.read(savedNetworkDevicesProvider).single;
    expect(saved.id, 'hn:tv.local');
    expect(saved.category, 'tv');
    expect(saved.host, '192.168.1.20');

    // The lease moved and the next open carried no match context — the
    // cache refreshes, the classification survives.
    await notifier.touch(_sighting(host: '192.168.1.77'));
    saved = c.read(savedNetworkDevicesProvider).single;
    expect(saved.host, '192.168.1.77');
    expect(saved.category, 'tv');
    expect(saved.specKey, 'Roku External Control Protocol|Roku');
  });

  group('a thinner sighting never erases what a richer one established', () {
    // Sightings are not equally rich: the same device answers mDNS with a TXT
    // map and no SSDP targets one session, and SSDP with targets and no TXT
    // the next. Blind-overwriting lost whichever half the latest transport did
    // not carry, which is how an adopted robot became unopenable from Saved
    // Devices and a Wemo stopped resolving its controls.
    NetworkDevice thin({
      String host = '192.168.1.20',
      String? hostname = 'tv.local',
      Map<String, String> txt = const {},
    }) =>
        NetworkDevice(
          host: host,
          name: 'Living Room TV',
          hostname: hostname,
          sources: const {NetworkDiscoverySource.mdns},
          discoveredAt: DateTime(2026, 1, 2),
          txt: txt,
        );

    test('the SSDP answers and ports survive a sighting that carries none',
        () async {
      final c = await container();
      final notifier = c.read(savedNetworkDevicesProvider.notifier);

      await notifier.touch(_sighting());
      await notifier.touch(thin());

      final saved = c.read(savedNetworkDevicesProvider).single;
      expect(saved.ssdpTargets, ['roku:ecp'],
          reason: 'the targets are what narrow a family spec to this model');
      expect(saved.ssdpPort, 8060);
      expect(saved.port, 8060);
      expect(saved.hostname, 'tv.local');
    });

    test('a nameless sighting keeps the saved name', () async {
      // A probe reply or a nameless SSDP answer carries no name, only a
      // hostname-or-address fallback; the most visible field must follow
      // the same rule as every other — only what the sighting carries.
      final c = await container();
      final notifier = c.read(savedNetworkDevicesProvider.notifier);

      await notifier.touch(_sighting());
      final named = c.read(savedNetworkDevicesProvider).single.name;
      expect(named, isNotEmpty);

      await notifier.touch(NetworkDevice(
        host: '192.168.1.20',
        name: '',
        hostname: 'tv.local',
        sources: const {NetworkDiscoverySource.mdns},
        discoveredAt: DateTime(2026, 1, 3),
      ));

      expect(c.read(savedNetworkDevicesProvider).single.name, named);
    });

    test('a TXT-less sighting rejoins its record instead of forking a second',
        () async {
      // The record is filed under `mac:` — read out of TXT. A sighting with no
      // TXT proposes `hn:` instead, so looking up by the proposed id alone
      // found nothing and wrote a SECOND row: the user saw two robots, and the
      // one they tapped had no blid to find the password by.
      final c = await container();
      final notifier = c.read(savedNetworkDevicesProvider.notifier);

      final first = await notifier.touch(thin(
        txt: const {'mac': 'AA:BB:CC:DD:EE:FF', 'blid': 'ABC123'},
      ));
      expect(first.id, startsWith('mac:'));

      await notifier.touch(thin(host: '192.168.1.77'));

      final saved = c.read(savedNetworkDevicesProvider).single;
      expect(saved.id, first.id);
      expect(saved.host, '192.168.1.77', reason: 'the lease still refreshes');
      expect(saved.txt['blid'], 'ABC123');
    });

    test('a bare TXT flag does not blank an established identity', () async {
      // A TXT record may carry a key with no value, which the parser stores as
      // an empty string. An empty blid is not an identity — it looks up no
      // password — so it must not replace the one already known.
      final c = await container();
      final notifier = c.read(savedNetworkDevicesProvider.notifier);

      await notifier.touch(thin(txt: const {'blid': 'ABC123'}));
      await notifier.touch(thin(txt: const {'blid': '', 'sku': 'j7'}));

      final saved = c.read(savedNetworkDevicesProvider).single;
      expect(saved.txt['blid'], 'ABC123');
      expect(saved.txt['sku'], 'j7', reason: 'a real new key still lands');
    });
  });

  test('forgetNetworkDevice prunes the namespaced membership first', () async {
    final c = await container();
    final savedNetwork = c.read(savedNetworkDevicesProvider.notifier);
    final groups = c.read(deviceGroupsProvider.notifier);

    final record = await savedNetwork.touch(_sighting(), category: 'tv');
    await groups.create(
      name: 'Evening',
      deviceIds: ['AA:BB', networkMemberId(record.id)],
    );

    await forgetNetworkDevice(
      savedDevices: savedNetwork,
      groups: groups,
      deviceId: record.id,
    );

    expect(c.read(savedNetworkDevicesProvider), isEmpty);
    final group = c.read(deviceGroupsProvider).single;
    expect(group.deviceIds, ['AA:BB'],
        reason: 'the BLE member stays; the network membership is pruned');
  });

  test('member id namespace round-trips and never collides with bare ids', () {
    final memberId = networkMemberId('hn:tv.local');
    expect(isNetworkMemberId(memberId), isTrue);
    expect(networkDeviceIdOf(memberId), 'hn:tv.local');
    expect(isNetworkMemberId('AA:BB:CC:DD:EE:FF'), isFalse);
    expect(
      const DeviceGroup(id: 'g', name: 'G', deviceIds: ['AA:BB'])
          .deviceIds
          .any(isNetworkMemberId),
      isFalse,
      reason: 'legacy bare ids read as BLE',
    );
  });
}
