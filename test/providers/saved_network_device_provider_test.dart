// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/device_group_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_network_device_provider.dart';
import 'package:liberated_bread_mobile/services/device_credential_store.dart';
import 'package:liberated_bread_mobile/services/device_group_store.dart';
import 'package:liberated_bread_mobile/services/tls_trust.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/in_memory_settings_store.dart';

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

    test('two devices behind one address do not fold into one record',
        () async {
      // The (host, name) rung is the weakest, and one address can front more
      // than one logical device. A sighting that states a hostname the saved
      // record contradicts is a different device, however much the address
      // and the display name agree.
      final c = await container();
      final notifier = c.read(savedNetworkDevicesProvider.notifier);

      await notifier.touch(thin(hostname: 'tv.local'));
      await notifier.touch(thin(hostname: 'speaker.local'));

      final saved = c.read(savedNetworkDevicesProvider);
      expect(saved, hasLength(2),
          reason: 'contradicting hostnames are two devices, not one');
    });

    test('a sighting that states nothing still rejoins its record', () async {
      // The other half of the rule: silence is not disagreement. This is the
      // case the rung exists for — an SSDP sighting of a device first seen
      // over mDNS carries no hostname at all.
      final c = await container();
      final notifier = c.read(savedNetworkDevicesProvider.notifier);

      await notifier.touch(thin(hostname: 'tv.local'));
      await notifier.touch(thin(hostname: null));

      expect(c.read(savedNetworkDevicesProvider), hasLength(1));
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

    final settings = InMemorySettingsStore();
    await forgetNetworkDevice(
      savedDevices: savedNetwork,
      groups: groups,
      deviceId: record.id,
      trust: TlsTrust(CertificatePinStore(settings)),
      credentials: DeviceCredentialStore(settings),
      host: record.host,
    );

    expect(c.read(savedNetworkDevicesProvider), isEmpty);
    final group = c.read(deviceGroupsProvider).single;
    expect(group.deviceIds, ['AA:BB'],
        reason: 'the BLE member stays; the network membership is pruned');
  });

  test('forgetting clears the pin and credentials under BOTH identity forms',
      () async {
    final c = await container();
    final savedNetwork = c.read(savedNetworkDevicesProvider.notifier);
    final groups = c.read(deviceGroupsProvider.notifier);
    final record = await savedNetwork.touch(_sighting(), category: 'tv');

    // The pin was written by the LIVE sender, which had the scan's mac; the
    // credential by a screen keyed the same way. The forget flow derives its
    // identity from the SAVED record — and the two views can disagree, which
    // used to leave a pin nothing could erase after the only recovery the
    // app offers.
    final settings = InMemorySettingsStore();
    final pins = CertificatePinStore(settings);
    final credentials = DeviceCredentialStore(settings);
    const mac = 'aa:bb:cc:dd:ee:ff';
    final host = record.host;
    await pins.save(identityFor(mac: mac, host: host), 'fp-mac');
    await pins.save(identityFor(host: host), 'fp-host');
    await credentials.save(identityFor(host: host), 'samsung_token', 't');

    await forgetNetworkDevice(
      savedDevices: savedNetwork,
      groups: groups,
      deviceId: record.id,
      trust: TlsTrust(pins),
      credentials: credentials,
      deviceMac: mac,
      host: host,
    );

    expect(await pins.pin(identityFor(mac: mac, host: host)), isNull);
    expect(await pins.pin(identityFor(host: host)), isNull);
    expect(await credentials.credentials(identityFor(host: host)), isEmpty);
  });

  /// The record now REMEMBERS the identity its pins were written under, so
  /// Remove clears the mac-keyed pin even when the saved record itself never
  /// captured the mac — the direction the both-forms fallback cannot reach.
  test('forgetting clears the pin under the identity recorded at write time',
      () async {
    final c = await container();
    final savedNetwork = c.read(savedNetworkDevicesProvider.notifier);
    final groups = c.read(deviceGroupsProvider.notifier);
    final record = await savedNetwork.touch(_sighting(), category: 'tv');

    final settings = InMemorySettingsStore();
    final pins = CertificatePinStore(settings);
    final credentials = DeviceCredentialStore(settings);
    // The live sender pinned under a mac the SAVED record does not know
    // (an SSDP-only record, a mac-bearing scan): only the recorded identity
    // can name it at forget time.
    const liveIdentity = 'mac:aa:bb:cc:dd:ee:ff';
    await pins.save(liveIdentity, 'fp-live');
    await credentials.save(liveIdentity, 'samsung_token', 't');

    await forgetNetworkDevice(
      savedDevices: savedNetwork,
      groups: groups,
      deviceId: record.id,
      trust: TlsTrust(pins),
      credentials: credentials,
      host: record.host,
      recordedIdentity: liveIdentity,
    );

    expect(await pins.pin(liveIdentity), isNull,
        reason: 'the write-time identity is the one Remove must clear');
    expect(await credentials.credentials(liveIdentity), isEmpty);
  });

  /// touch() records the sighting's own store identity, and a later thin
  /// sighting must not downgrade a `mac:` identity to `host:` — the
  /// mac-keyed pin would outlive the record's memory of it.
  test('touch records the credential identity, strongest form winning',
      () async {
    final c = await container();
    final savedNetwork = c.read(savedNetworkDevicesProvider.notifier);

    // A mac-bearing sighting: the identity the sender pins under.
    final rich = await savedNetwork.touch(NetworkDevice(
      host: '192.168.1.20',
      name: 'Living Room TV',
      hostname: 'tv.local',
      txt: const {'mac': 'AA:BB:CC:DD:EE:FF'},
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime.utc(2026),
    ));
    expect(rich.credentialIdentity, 'mac:aa:bb:cc:dd:ee:ff');

    // A thin re-sighting: same device, no TXT (so no mac to derive).
    final thin = await savedNetwork.touch(NetworkDevice(
      host: '192.168.1.20',
      name: 'Living Room TV',
      hostname: 'tv.local',
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime.utc(2026, 2),
    ));
    expect(thin.credentialIdentity, 'mac:aa:bb:cc:dd:ee:ff',
        reason: 'a mac: identity is never downgraded by a thin sighting');
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
