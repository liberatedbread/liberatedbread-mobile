// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../core/hex.dart';
import '../services/device_group_store.dart';
import '../services/group_runner.dart';
import '../services/saved_device_store.dart';
import 'ble_provider.dart';
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';
import 'scan_match_provider.dart';
import 'spec_choice_provider.dart';
import 'spec_codec_provider.dart';

/// Categories that never take part in grouping: `reference` specs document a
/// protocol rather than a device, and `vehicle` covers OBD dongles — serial
/// bridges into a car, not endpoints a bulk on/off or battery sweep should
/// ever touch.
const Set<DeviceCategory> kNonGroupableCategories = {
  DeviceCategory.reference,
  DeviceCategory.vehicle,
};

/// Whether a device with this recorded `device.category` value may take part
/// in groups. The one spelling of the rule — the members provider, the group
/// editor's candidate list and save filter, and the tile counts all call
/// this, so they cannot drift on which devices a run would actually touch.
/// Null (kind not known yet) is groupable: battery reads need no spec, and
/// the runner matches one on connect.
bool isGroupable(String? category) =>
    !kNonGroupableCategories.contains(DeviceCategory.parse(category));

final deviceGroupStoreProvider = Provider<DeviceGroupStore>(
  (ref) => DeviceGroupStore(ref.watch(sharedPreferencesProvider)),
);

/// The user's custom groups, in creation order.
class DeviceGroupsNotifier extends StateNotifier<List<DeviceGroup>> {
  final DeviceGroupStore _store;

  /// Tie-break suffix for [create]'s ids. `DateTime.now()` is only
  /// millisecond-precise on some platforms (web), where two quick creations
  /// could mint the same stamp — and identical ids make the second group
  /// silently overwrite the first in the store. Static so notifiers recreated
  /// by provider rebuilds keep counting instead of restarting at zero.
  static int _creationSeq = 0;

  DeviceGroupsNotifier(this._store) : super(_store.load());

  Future<DeviceGroup> create({
    required String name,
    required List<String> deviceIds,
  }) async {
    final group = DeviceGroup(
      // Stamp + sequence over a uuid dependency: ids only need to be unique
      // within one user's handful of groups, and creation is a user gesture.
      id: 'g${DateTime.now().microsecondsSinceEpoch}-${_creationSeq++}',
      name: name,
      deviceIds: deviceIds,
    );
    state = await _store.save(group);
    return group;
  }

  Future<void> update(DeviceGroup group) async {
    state = await _store.save(group);
  }

  Future<void> remove(String id) async {
    state = await _store.remove(id);
  }

  /// Drop a forgotten device from every group, so its membership cannot
  /// resurrect when the same device is saved again later.
  Future<void> pruneDevice(String deviceId) async {
    state = await _store.removeDevice(deviceId);
  }
}

final deviceGroupsProvider =
    StateNotifierProvider<DeviceGroupsNotifier, List<DeviceGroup>>(
  (ref) => DeviceGroupsNotifier(ref.watch(deviceGroupStoreProvider)),
);

/// Forget a saved device everywhere, in the one crash-safe order.
///
/// Group membership goes first: dying between the two writes then leaves a
/// saved device with no memberships (harmless), never a stored membership
/// without a device — that one silently resurrects if the same id is ever
/// saved again. Takes the notifiers rather than a ref so callers are forced
/// to resolve them before their first await (reading a ref after an async
/// gap throws once the calling widget is disposed), and so every future
/// forget path gets the cascade by construction instead of remembering to
/// copy it.
Future<void> forgetDevice({
  required SavedDevicesNotifier savedDevices,
  required DeviceGroupsNotifier groups,
  required String deviceId,
}) async {
  await groups.pruneDevice(deviceId);
  await savedDevices.remove(deviceId);
}

/// One automatic by-kind group ("Lights"), derived from the saved devices.
@immutable
class AutoGroup {
  final DeviceCategory category;
  final List<SavedDevice> devices;

  const AutoGroup({required this.category, required this.devices});
}

/// The saved devices bucketed by kind, plus the ones no kind is known for
/// yet — surfaced separately so they read as "connect once to identify"
/// rather than silently missing from every group.
@immutable
class AutoGroups {
  final List<AutoGroup> groups;
  final List<SavedDevice> unidentified;

  const AutoGroups({required this.groups, required this.unidentified});
}

/// Bucket the saved devices by category.
///
/// A device's category is normally the one recorded when a spec match
/// resolved during a connection. Records saved before that existed (or whose
/// match never resolved) get a display-only guess through the same
/// scan-matching the Nearby list uses — name and MAC prefix are usually
/// enough — which is never written back to storage; connecting to the device
/// once records the real answer.
final autoGroupsProvider = FutureProvider<AutoGroups>((ref) async {
  final saved = ref.watch(savedDevicesProvider);

  // Two passes on purpose. The first is synchronous and does every ref.watch
  // up front: watching after an await is unsound (this build may already be
  // stale by then), and holding all the futures before awaiting lets the
  // guesses resolve concurrently instead of serializing one FFI match per
  // unclassified device.
  final categories = List<DeviceCategory?>.filled(saved.length, null);
  final guessIndexes = <int>[];
  final guessFutures = <Future<ScanGuess?>>[];
  for (var i = 0; i < saved.length; i++) {
    final device = saved[i];
    categories[i] = DeviceCategory.parse(device.category);
    if (categories[i] == null) {
      guessIndexes.add(i);
      guessFutures.add(ref.watch(scanGuessProvider(ScanIdentity(
        name: device.name,
        serviceUuids: const [],
        companyIds: const [],
        // [SavedDevice.id] is only a MAC on some platforms; Apple substitutes
        // an opaque UUID, which must not be offered as an address.
        macAddress: macAddressOrNull(device.id),
      )).future));
    }
  }
  final guesses = await Future.wait(guessFutures);
  for (var g = 0; g < guesses.length; g++) {
    categories[guessIndexes[g]] = guesses[g]?.category;
  }

  final byCategory = <DeviceCategory, List<SavedDevice>>{};
  final unidentified = <SavedDevice>[];
  for (var i = 0; i < saved.length; i++) {
    final category = categories[i];
    if (category == null) {
      unidentified.add(saved[i]);
    } else if (!kNonGroupableCategories.contains(category)) {
      byCategory.putIfAbsent(category, () => []).add(saved[i]);
    }
  }

  final groups = [
    for (final entry in byCategory.entries)
      AutoGroup(category: entry.key, devices: entry.value),
  ]..sort((a, b) => a.category.label.compareTo(b.category.label));
  return AutoGroups(groups: groups, unidentified: unidentified);
});

/// Family key for [groupMembersProvider]: value equality over the member ids,
/// for the same reason [SpecMatchRequest] is a class — a fresh list instance
/// per rebuild must not defeat the family cache.
@immutable
class GroupMembersRequest {
  final List<String> deviceIds;

  const GroupMembersRequest(this.deviceIds);

  @override
  bool operator ==(Object other) =>
      other is GroupMembersRequest && listEquals(other.deviceIds, deviceIds);

  @override
  int get hashCode => Object.hashAll(deviceIds);
}

/// Resolve saved devices into runnable [GroupMember]s: each member carries
/// its spec when one can be found without a connection. Resolution order is
/// the user's explicit per-device spec choice, then the match recorded at
/// last connect; a member with neither still runs (the runner matches after
/// discovery, and battery reads work spec-less). Ids no longer in the saved
/// list are dropped — a forgotten device leaves its groups.
final groupMembersProvider = FutureProvider.autoDispose
    .family<List<GroupMember>, GroupMembersRequest>((ref, request) async {
  final saved = ref.watch(savedDevicesProvider);
  final choices = ref.watch(specChoicesProvider);
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);

  final savedById = {for (final device in saved) device.id: device};
  // Built through specEntriesByKey so the pack-shadows-bundled rule for
  // duplicate keys stays defined in exactly one place.
  final entriesByKey = specEntriesByKey(parsed);

  final members = <GroupMember>[];
  for (final id in request.deviceIds) {
    final device = savedById[id];
    if (device == null) continue;
    // Enforced at run time, not just in the pickers: a member that recorded
    // a non-groupable category AFTER joining a group (an unidentified device
    // that turned out to be an OBD dongle) must not keep taking part through
    // its stale membership.
    if (!isGroupable(device.category)) continue;
    final resolved = entriesByKey[choices[id]] ?? entriesByKey[device.specKey];
    members.add(GroupMember(
      id: id,
      name: device.name,
      spec: resolved?.spec,
      specYaml: resolved?.yaml,
    ));
  }
  return members;
});

/// The group-operation executor, wired to the live BLE service and codec.
/// The resolver closure gives the runner the same post-discovery matching a
/// device screen would do, for members whose spec is not stored — built
/// through the same factory as every other post-discovery call site, so the
/// family cache is shared with the panel rather than raced.
final groupRunnerProvider = Provider<GroupRunner>((ref) {
  return GroupRunner(
    ble: ref.watch(bleServiceProvider),
    codec: ref.watch(specCodecProvider),
    resolveSpec: (member, services) async {
      final outcome =
          await ref.read(matchedDeviceSpecProvider(SpecMatchRequest.forServices(
        deviceId: member.id,
        deviceName: member.name,
        services: services,
      )).future);
      final chosen = outcome.chosen;
      return chosen == null ? null : (spec: chosen.spec, yaml: chosen.yaml);
    },
  );
});
