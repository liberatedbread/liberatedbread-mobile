// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../core/hex.dart';
import '../services/device_group_store.dart';
import '../services/group_runner.dart';
import '../services/saved_device_store.dart';
import '../services/spec_codec.dart';
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

final deviceGroupStoreProvider = Provider<DeviceGroupStore>(
  (ref) => DeviceGroupStore(ref.watch(sharedPreferencesProvider)),
);

/// The user's custom groups, in creation order.
class DeviceGroupsNotifier extends StateNotifier<List<DeviceGroup>> {
  final DeviceGroupStore _store;

  DeviceGroupsNotifier(this._store) : super(_store.load());

  Future<DeviceGroup> create({
    required String name,
    required List<String> deviceIds,
  }) async {
    final group = DeviceGroup(
      // Microsecond stamp over a uuid dependency: ids only need to be unique
      // within one user's handful of groups, and creation is a user gesture.
      id: 'g${DateTime.now().microsecondsSinceEpoch}',
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

/// [SavedDevice.id] as a MAC when it is one, for the scan-matcher's OUI axis.
/// Apple platforms use opaque UUIDs as device ids, which must not be offered
/// as addresses.
@visibleForTesting
String? macAddressOfSavedId(String id) {
  final parts = id.split(':');
  if (parts.length != 6) return null;
  final hex = RegExp(r'^[0-9A-Fa-f]{2}$');
  return parts.every(hex.hasMatch) ? id : null;
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
  final byCategory = <DeviceCategory, List<SavedDevice>>{};
  final unidentified = <SavedDevice>[];

  for (final device in saved) {
    var category = DeviceCategory.parse(device.category);
    if (category == null) {
      final guess = await ref.watch(scanGuessProvider(ScanIdentity(
        name: device.name,
        serviceUuids: const [],
        companyIds: const [],
        macAddress: macAddressOfSavedId(device.id),
      )).future);
      category = guess?.category;
    }
    if (category == null) {
      unidentified.add(device);
    } else if (!kNonGroupableCategories.contains(category)) {
      byCategory.putIfAbsent(category, () => []).add(device);
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

  ({DeviceSpecDto spec, String yaml})? bySpecKey(String? key) {
    if (key == null) return null;
    // lastWhere, matching matchedDeviceSpecProvider's resolve(): remote pack
    // specs load after bundled ones and shadow them on identity collisions.
    for (final entry in parsed.reversed) {
      if (specKeyFor(entry.spec) == key) return entry;
    }
    return null;
  }

  final members = <GroupMember>[];
  for (final id in request.deviceIds) {
    final device = saved.where((d) => d.id == id).firstOrNull;
    if (device == null) continue;
    // Enforced at run time, not just in the pickers: a member that recorded
    // a non-groupable category AFTER joining a group (an unidentified device
    // that turned out to be an OBD dongle) must not keep taking part through
    // its stale membership.
    if (kNonGroupableCategories.contains(DeviceCategory.parse(device.category))) {
      continue;
    }
    final resolved = bySpecKey(choices[id]) ?? bySpecKey(device.specKey);
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
/// device screen would do, for members whose spec is not stored — built with
/// the identical normalized-and-sorted UUID key so the family cache is shared
/// with the panel rather than raced.
final groupRunnerProvider = Provider<GroupRunner>((ref) {
  return GroupRunner(
    ble: ref.watch(bleServiceProvider),
    codec: ref.watch(specCodecProvider),
    resolveSpec: (member, services) async {
      final serviceUuids = [for (final s in services) normalizeUuid(s.uuid)]
        ..sort();
      final outcome = await ref.read(matchedDeviceSpecProvider(SpecMatchRequest(
        deviceId: member.id,
        deviceName: member.name,
        serviceUuids: serviceUuids,
      )).future);
      final chosen = outcome.chosen;
      return chosen == null ? null : (spec: chosen.spec, yaml: chosen.yaml);
    },
  );
});
