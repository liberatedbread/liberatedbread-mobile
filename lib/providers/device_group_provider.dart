// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../core/hex.dart';
import '../services/device_group_store.dart';
import '../services/group_runner.dart';
import '../services/saved_device_store.dart';
import '../services/saved_network_device_store.dart';
import 'ble_provider.dart';
import 'device_spec_match_provider.dart';
import 'network_control_provider.dart';
import 'saved_device_provider.dart';
import 'saved_network_device_provider.dart';
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

/// [forgetDevice]'s network sibling, with the same crash-safe order. The
/// membership pruned is the namespaced form — see [networkMemberId] —
/// because that is how network devices appear in a group's member list.
Future<void> forgetNetworkDevice({
  required SavedNetworkDevicesNotifier savedDevices,
  required DeviceGroupsNotifier groups,
  required String deviceId,
}) async {
  await groups.pruneDevice(networkMemberId(deviceId));
  await savedDevices.remove(deviceId);
}

/// How a network device's id is spelled inside [DeviceGroup.deviceIds].
///
/// BLE ids stay bare — every membership stored before Wi-Fi devices could
/// join reads exactly as it always did — and network members carry this
/// prefix, which no BLE id can collide with (a MAC or CoreBluetooth UUID
/// never contains `net:`).
const String kNetworkMemberPrefix = 'net:';

String networkMemberId(String savedNetworkDeviceId) =>
    '$kNetworkMemberPrefix$savedNetworkDeviceId';

bool isNetworkMemberId(String memberId) =>
    memberId.startsWith(kNetworkMemberPrefix);

/// The store id inside a namespaced network member id.
String networkDeviceIdOf(String memberId) =>
    memberId.substring(kNetworkMemberPrefix.length);

/// One automatic by-kind group ("Lights", "TVs"), derived from the saved
/// devices of both transports. The two lists stay separate because their
/// records are different classes with different id namespaces; a consumer
/// wanting "how many" adds the lengths, and one wanting member ids maps
/// each through its own spelling.
@immutable
class AutoGroup {
  final DeviceCategory category;
  final List<SavedDevice> devices;
  final List<SavedNetworkDevice> networkDevices;

  const AutoGroup({
    required this.category,
    required this.devices,
    this.networkDevices = const [],
  });

  int get memberCount => devices.length + networkDevices.length;

  /// Every member in this bucket, in group-member-id spelling: bare BLE
  /// ids, namespaced network ids — exactly what [GroupMembersRequest]
  /// takes.
  List<String> get memberIds => [
        for (final device in devices) device.id,
        for (final device in networkDevices) networkMemberId(device.id),
      ];
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
  // Watched here with everything else, before the first await — watching
  // after an await is unsound, as the comment below explains.
  final savedNetwork = ref.watch(savedNetworkDevicesProvider);

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

  // Saved network devices join the same buckets — this is where "TVs"
  // comes from. Their category was recorded from the spec match at save
  // time; a record without one (a spec that states no category) simply
  // stays out of the by-kind lists, still reachable from Saved and from
  // custom groups — there is no scan-guess path to invent one from.
  final networkByCategory = <DeviceCategory, List<SavedNetworkDevice>>{};
  for (final device in savedNetwork) {
    final category = DeviceCategory.parse(device.category);
    if (category == null || kNonGroupableCategories.contains(category)) {
      continue;
    }
    networkByCategory.putIfAbsent(category, () => []).add(device);
  }

  final groups = [
    for (final category in {...byCategory.keys, ...networkByCategory.keys})
      AutoGroup(
        category: category,
        devices: byCategory[category] ?? const [],
        networkDevices: networkByCategory[category] ?? const [],
      ),
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

/// A group's resolved members, both transports, in membership order within
/// each transport. Kept as two lists rather than one union type because the
/// two runners take different inputs and run under different disciplines —
/// see [NetworkGroupRunner]'s class doc.
@immutable
class GroupMembers {
  final List<GroupMember> ble;
  final List<NetworkGroupMember> network;

  const GroupMembers({required this.ble, required this.network});

  int get length => ble.length + network.length;
  bool get isEmpty => ble.isEmpty && network.isEmpty;
}

/// Resolve saved devices into runnable members: each member carries its
/// spec when one can be found without a connection. For BLE ids the order
/// is the user's explicit per-device spec choice, then the match recorded
/// at last connect; a member with neither still runs (the runner matches
/// after discovery, and battery reads work spec-less). Network ids resolve
/// their controls through the same family the Wi-Fi tiles watch. Ids no
/// longer in either saved list are dropped — a forgotten device leaves its
/// groups.
final groupMembersProvider = FutureProvider.autoDispose
    .family<GroupMembers, GroupMembersRequest>((ref, request) async {
  final saved = ref.watch(savedDevicesProvider);
  final savedNetwork = ref.watch(savedNetworkDevicesProvider);
  final choices = ref.watch(specChoicesProvider);

  // Everything watched before the first await, futures gathered up front —
  // the same two-pass discipline as autoGroupsProvider, and for the same
  // soundness reason.
  final parsedFuture = ref.watch(parsedDeviceSpecsProvider.future);
  final savedNetworkById = {
    for (final device in savedNetwork) device.id: device
  };
  final networkIds = <String>[];
  final controlsFutures = <Future<NetworkControls?>?>[];
  for (final id in request.deviceIds) {
    if (!isNetworkMemberId(id)) continue;
    final device = savedNetworkById[networkDeviceIdOf(id)];
    if (device == null || !isGroupable(device.category)) continue;
    networkIds.add(id);
    final parts = device.specKey?.split('|');
    controlsFutures.add(parts != null && parts.length == 2
        ? ref.watch(networkControlsProvider(NetworkControlRequest(
            deviceName: parts[0],
            manufacturer: parts[1],
            ssdpTargets: device.ssdpTargets,
          )).future)
        : null);
  }

  final parsed = await parsedFuture;
  final savedById = {for (final device in saved) device.id: device};
  // Built through specEntriesByKey so the pack-shadows-bundled rule for
  // duplicate keys stays defined in exactly one place.
  final entriesByKey = specEntriesByKey(parsed);

  final ble = <GroupMember>[];
  for (final id in request.deviceIds) {
    if (isNetworkMemberId(id)) continue;
    final device = savedById[id];
    if (device == null) continue;
    // Enforced at run time, not just in the pickers: a member that recorded
    // a non-groupable category AFTER joining a group (an unidentified device
    // that turned out to be an OBD dongle) must not keep taking part through
    // its stale membership.
    if (!isGroupable(device.category)) continue;
    final resolved = entriesByKey[choices[id]] ?? entriesByKey[device.specKey];
    ble.add(GroupMember(
      id: id,
      name: device.name,
      spec: resolved?.spec,
      specYaml: resolved?.yaml,
    ));
  }

  final network = <NetworkGroupMember>[];
  for (var i = 0; i < networkIds.length; i++) {
    final id = networkIds[i];
    final device = savedNetworkById[networkDeviceIdOf(id)]!;
    // A controls resolution that failed resolves to null (the family's own
    // contract), leaving a member whose row and runner both report the
    // honest "no spec matched" rather than dropping the device.
    final controls = await controlsFutures[i];
    network.add(NetworkGroupMember(
      memberId: id,
      name: device.name,
      category: device.category,
      record: device,
      specYaml: controls?.specYaml,
      entities: controls?.entities ?? const [],
    ));
  }
  return GroupMembers(ble: ble, network: network);
});

/// The Wi-Fi group executor, wired to the same sender factory and transport
/// clients the device screen uses — so a group send and a screen tap are
/// the same exchange.
final networkGroupRunnerProvider = Provider<NetworkGroupRunner>((ref) {
  return NetworkGroupRunner(
    codec: ref.watch(specCodecProvider),
    soap: ref.watch(soapControlClientProvider),
    senderFor: ref.watch(networkCommandSenderFactoryProvider),
  );
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
