// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_choice_provider.dart';
import 'package:liberated_bread_mobile/providers/device_group_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/device_group_store.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/saved_device_store.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _chr = '0000fff1-0000-1000-8000-00805f9b34fb';

DeviceSpecDto _bulbSpec({String name = 'Example Smart Bulb'}) => DeviceSpecDto(
      deviceName: name,
      manufacturer: 'Acme Corp',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefixes: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      services: const [],
      entities: const [
        EntityDto(
          name: 'Bulb',
          platform: 'light',
          canNotify: false,
          hasFormat: false,
          onWhenNonzero: false,
          actions: [
            EntityActionDto(
              role: 'turn_off',
              serviceUuid: _svc,
              characteristicUuid: _chr,
              commandName: 'power_off',
              userParams: [],
            ),
          ],
        ),
      ],
    );

Future<ProviderContainer> _container(
    {List<Override> overrides = const []}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    ...overrides,
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seen = DateTime(2026, 8, 11, 10);

  group('deviceGroupsProvider', () {
    test('create, update and remove round-trip through the store', () async {
      final container = await _container();
      final notifier = container.read(deviceGroupsProvider.notifier);

      final group =
          await notifier.create(name: 'Living Room', deviceIds: ['A', 'B']);
      expect(container.read(deviceGroupsProvider).single.name, 'Living Room');

      await notifier.update(group.copyWith(deviceIds: ['A']));
      expect(container.read(deviceGroupsProvider).single.deviceIds, ['A']);

      await notifier.remove(group.id);
      expect(container.read(deviceGroupsProvider), isEmpty);
    });

    test('created groups get distinct ids', () async {
      final container = await _container();
      final notifier = container.read(deviceGroupsProvider.notifier);
      final a = await notifier.create(name: 'A', deviceIds: []);
      final b = await notifier.create(name: 'B', deviceIds: []);
      expect(a.id, isNot(b.id));
    });
  });

  group('autoGroupsProvider', () {
    ScanGuess guess(DeviceCategory category) => ScanGuess(
          deviceName: 'Guessed',
          manufacturer: 'Acme',
          confidence: MatchConfidence.likely,
          otherMatches: 0,
          manufacturerAgreed: true,
          category: category,
        );

    test('buckets stored categories and excludes non-groupable ones', () async {
      final container = await _container(overrides: [
        scanGuessProvider.overrideWith((ref, identity) async => null),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(SavedDevice(
          id: 'L1', name: 'Bulb', lastSeen: seen, category: 'light'));
      await saved.save(SavedDevice(
          id: 'L2', name: 'Bulb 2', lastSeen: seen, category: 'light'));
      await saved.save(SavedDevice(
          id: 'S1', name: 'Wave', lastSeen: seen, category: 'sensor'));
      await saved.save(SavedDevice(
          id: 'V1', name: 'OBD', lastSeen: seen, category: 'vehicle'));

      final auto = await container.read(autoGroupsProvider.future);
      expect(auto.groups, hasLength(2));
      final byCategory = {for (final g in auto.groups) g.category: g};
      expect(byCategory[DeviceCategory.light]!.devices, hasLength(2));
      expect(byCategory[DeviceCategory.sensor]!.devices, hasLength(1));
      // The OBD dongle is neither grouped nor "unidentified" — it is excluded.
      expect(byCategory.containsKey(DeviceCategory.vehicle), isFalse);
      expect(auto.unidentified, isEmpty);
    });

    test('a record without a category gets a display-only guess', () async {
      final container = await _container(overrides: [
        scanGuessProvider.overrideWith((ref, identity) async =>
            identity.name == 'ACME_Old' ? guess(DeviceCategory.light) : null),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(SavedDevice(id: 'A', name: 'ACME_Old', lastSeen: seen));
      await saved.save(SavedDevice(id: 'B', name: 'Mystery', lastSeen: seen));

      final auto = await container.read(autoGroupsProvider.future);
      expect(auto.groups.single.category, DeviceCategory.light);
      expect(auto.groups.single.devices.single.id, 'A');
      expect(auto.unidentified.single.id, 'B');
      // Display-only: nothing was written back to the record.
      expect(
        container
            .read(savedDevicesProvider)
            .firstWhere((d) => d.id == 'A')
            .category,
        isNull,
      );
    });

    test('offers the saved id to the matcher as a MAC only when it is one',
        () async {
      final identities = <ScanIdentity>[];
      final container = await _container(overrides: [
        scanGuessProvider.overrideWith((ref, identity) async {
          identities.add(identity);
          return null;
        }),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(
          SavedDevice(id: 'AA:BB:CC:DD:EE:01', name: 'Mac', lastSeen: seen));
      // A CoreBluetooth UUID must not be offered as an address.
      await saved.save(SavedDevice(
          id: '4bb63e02-91b5-4a4f-9d63-cd0324a1a1ba',
          name: 'Apple',
          lastSeen: seen));

      await container.read(autoGroupsProvider.future);

      final byName = {
        for (final identity in identities) identity.name: identity
      };
      expect(byName['Mac']!.macAddress, 'AA:BB:CC:DD:EE:01');
      expect(byName['Apple']!.macAddress, isNull);
    });

    test('guesses for unclassified records resolve concurrently', () async {
      final started = <String>[];
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final container = await _container(overrides: [
        scanGuessProvider.overrideWith((ref, identity) async {
          started.add(identity.name);
          await gate.future;
          return guess(DeviceCategory.light);
        }),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(SavedDevice(id: 'A', name: 'One', lastSeen: seen));
      await saved.save(SavedDevice(id: 'B', name: 'Two', lastSeen: seen));

      final future = container.read(autoGroupsProvider.future);
      await Future<void>.delayed(Duration.zero);
      // Both matches must be in flight before either resolves — the serial
      // version would still be parked on the first one here, with the
      // second not yet started.
      expect(started, unorderedEquals(['One', 'Two']));

      gate.complete();
      final auto = await future;
      expect(auto.groups.single.devices, hasLength(2));
    });
  });

  group('isGroupable', () {
    test('excludes only the on-principle categories', () {
      expect(isGroupable('light'), isTrue);
      // Unknown kind stays groupable: battery reads need no spec, and the
      // runner can match one on connect.
      expect(isGroupable(null), isTrue);
      // So does a category minted upstream after this build shipped.
      expect(isGroupable('hologram'), isTrue);
      expect(isGroupable('vehicle'), isFalse);
      expect(isGroupable('reference'), isFalse);
    });
  });

  group('forgetDevice', () {
    test('prunes group memberships before the saved record', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final calls = <String>[];
      final savedNotifier =
          _RecordingSavedDevices(SavedDeviceStore(prefs), calls);
      final groupsNotifier = _RecordingGroups(DeviceGroupStore(prefs), calls);
      final container = ProviderContainer(overrides: [
        savedDevicesProvider.overrideWith((ref) => savedNotifier),
        deviceGroupsProvider.overrideWith((ref) => groupsNotifier),
      ]);
      addTearDown(container.dispose);
      await savedNotifier
          .save(SavedDevice(id: 'A', name: 'Bulb', lastSeen: seen));
      await groupsNotifier.create(name: 'Room', deviceIds: ['A']);

      await forgetDevice(
        savedDevices: savedNotifier,
        groups: groupsNotifier,
        deviceId: 'A',
      );

      // Membership first: dying between the writes must leave a spec-less
      // saved device, never a dormant membership that resurrects on re-save.
      expect(calls, ['pruneDevice', 'remove']);
      expect(container.read(savedDevicesProvider), isEmpty);
      expect(container.read(deviceGroupsProvider).single.deviceIds, isEmpty);
    });
  });

  group('groupMembersProvider', () {
    test('resolves specs by choice first, then the saved match', () async {
      final chosen = _bulbSpec(name: 'Chosen Bulb');
      final recorded = _bulbSpec(name: 'Recorded Bulb');
      final container = await _container(overrides: [
        parsedDeviceSpecsProvider.overrideWith((ref) async => [
              (spec: chosen, yaml: 'chosen-yaml'),
              (spec: recorded, yaml: 'recorded-yaml'),
            ]),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(SavedDevice(
        id: 'A',
        name: 'Bulb A',
        lastSeen: seen,
        specKey: specKeyFor(recorded),
      ));
      await saved.save(SavedDevice(
        id: 'B',
        name: 'Bulb B',
        lastSeen: seen,
        specKey: specKeyFor(recorded),
      ));
      // The user explicitly picked a different spec for A.
      await container
          .read(specChoicesProvider.notifier)
          .choose('A', specKeyFor(chosen));

      final members = await container.read(
        groupMembersProvider(const GroupMembersRequest(['A', 'B'])).future,
      );
      final byId = {for (final m in members) m.id: m};
      expect(byId['A']!.specYaml, 'chosen-yaml');
      expect(byId['B']!.specYaml, 'recorded-yaml');
      // Members arrive with their op memo already derived from the spec.
      expect(byId['A']!.specOps, contains(GroupOp.turnOff));
    });

    test('drops forgotten ids and carries members with no spec', () async {
      final container = await _container(overrides: [
        parsedDeviceSpecsProvider.overrideWith((ref) async => []),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(SavedDevice(id: 'A', name: 'Known', lastSeen: seen));

      final members = await container.read(
        groupMembersProvider(const GroupMembersRequest(['A', 'GONE'])).future,
      );
      expect(members.single.id, 'A');
      expect(members.single.spec, isNull);
    });

    test('a member that recorded a non-groupable category stops running',
        () async {
      // An unidentified member that later turns out to be an OBD dongle must
      // not keep taking part through its stale group membership.
      final container = await _container(overrides: [
        parsedDeviceSpecsProvider.overrideWith((ref) async => []),
      ]);
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(SavedDevice(
          id: 'A', name: 'Dongle', lastSeen: seen, category: 'vehicle'));
      await saved.save(SavedDevice(
          id: 'B', name: 'Bulb', lastSeen: seen, category: 'light'));

      final members = await container.read(
        groupMembersProvider(const GroupMembersRequest(['A', 'B'])).future,
      );
      expect(members.single.id, 'B');
    });

    test('pruneDevice drops a device from every stored group', () async {
      final container = await _container();
      final notifier = container.read(deviceGroupsProvider.notifier);
      await notifier.create(name: 'Room', deviceIds: ['A', 'B']);
      await notifier.create(name: 'Solo', deviceIds: ['A']);

      await notifier.pruneDevice('A');

      final groups = container.read(deviceGroupsProvider);
      expect(groups.first.deviceIds, ['B']);
      expect(groups.last.deviceIds, isEmpty);
    });
  });

  group('groupRunnerProvider', () {
    test('wires the post-discovery resolver through spec matching', () async {
      final ble = FakeBleService(servicesToReturn: const [
        BleDiscoveredService(uuid: _svc, characteristics: [
          BleDiscoveredCharacteristic(
            uuid: _chr,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ]),
      ]);
      final container = await _container(overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(
            FakeSpecCodec(encoded: Uint8List.fromList([0x01]))),
        matchedDeviceSpecProvider.overrideWith((ref, request) async =>
            SpecMatchOutcome.auto(
                MatchedSpec(spec: _bulbSpec(), yaml: 'matched-yaml'))),
      ]);

      final runner = container.read(groupRunnerProvider);
      final events = await runner
          .run(
            GroupOp.turnOff,
            [GroupMember(id: 'A', name: 'Bulb')],
            stop: StopSignal(),
          )
          .toList();

      expect(events.last.status, GroupDeviceStatus.ok);
      expect(ble.writes.single.value, [0x01]);
    });
  });
}

/// Notifiers that log their forget-path calls, so the coordinator's write
/// order is observable.
class _RecordingSavedDevices extends SavedDevicesNotifier {
  final List<String> calls;

  _RecordingSavedDevices(super.store, this.calls);

  @override
  Future<void> remove(String id) {
    calls.add('remove');
    return super.remove(id);
  }
}

class _RecordingGroups extends DeviceGroupsNotifier {
  final List<String> calls;

  _RecordingGroups(super.store, this.calls);

  @override
  Future<void> pruneDevice(String deviceId) {
    calls.add('pruneDevice');
    return super.pruneDevice(deviceId);
  }
}
