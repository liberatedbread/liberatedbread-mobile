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
