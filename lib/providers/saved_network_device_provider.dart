// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/network_device.dart';
import '../services/saved_network_device_store.dart';
import 'saved_device_provider.dart';

final savedNetworkDeviceStoreProvider = Provider<SavedNetworkDeviceStore>(
  (ref) => SavedNetworkDeviceStore(ref.watch(sharedPreferencesProvider)),
);

/// The user's saved network devices, newest-first — the Wi-Fi sibling of
/// [SavedDevicesNotifier], kept a separate notifier for the same reason the
/// models are separate classes: the two lists change on different events
/// (a BLE connect vs. opening a network control screen) and merging them
/// would rebuild every watcher on both.
class SavedNetworkDevicesNotifier
    extends StateNotifier<List<SavedNetworkDevice>> {
  final SavedNetworkDeviceStore _store;

  SavedNetworkDevicesNotifier(this._store) : super(_store.load());

  Future<void> save(SavedNetworkDevice device) async {
    state = await _store.save(device);
  }

  Future<void> remove(String id) async {
    state = await _store.remove(id);
  }

  /// Record a sighting the user acted on — opening the control screen is
  /// the network counterpart of a BLE connect. Refreshes the address cache
  /// and the recency stamp, and records the spec identity/category when the
  /// caller knows them.
  ///
  /// Every cached field MERGES rather than replaces, because sightings are
  /// not equally rich: the same device answers mDNS with a TXT map and no
  /// SSDP targets one session, and SSDP with targets and no TXT the next.
  /// Blind-overwriting lost whichever half the latest transport did not
  /// carry — an adopted robot's `blid` (unopenable from Saved Devices), or a
  /// Wemo's search targets (which is what narrows a family spec, so its
  /// controls stopped resolving). A sighting can therefore only ADD to what
  /// is known, or refresh a value it actually carries.
  Future<SavedNetworkDevice> touch(
    NetworkDevice device, {
    String? category,
    String? specKey,
    DateTime? seenAt,
  }) async {
    final existing = _existingFor(device);
    final record = SavedNetworkDevice(
      // The record keeps the id it was filed under. The sighting's own id is
      // only a proposal, and a thinner sighting proposes a weaker one (no
      // TXT, so no `mac:` rung): re-filing under it would leave two rows for
      // one device, the tapped one missing the credential. It would also
      // orphan the device's group memberships, which reference this id.
      id: existing?.id ?? SavedNetworkDevice.stableIdFor(device),
      name: device.displayName,
      lastSeen: seenAt ?? DateTime.now(),
      // The address is the one field a fresh sighting always knows better:
      // it is where the device answered from just now.
      host: device.host,
      hostname: device.hostname ?? existing?.hostname,
      port: device.port ?? existing?.port,
      ssdpPort: device.ssdpPort ?? existing?.ssdpPort,
      ssdpDescriptionPath:
          device.ssdpDescriptionPath ?? existing?.ssdpDescriptionPath,
      ssdpTargets: device.ssdpTargets.isNotEmpty
          ? device.ssdpTargets
          : existing?.ssdpTargets ?? const [],
      serviceTypes: device.serviceTypes.isNotEmpty
          ? device.serviceTypes
          : existing?.serviceTypes ?? const [],
      answeredLanProtocols: device.answeredLanProtocols.isNotEmpty
          ? device.answeredLanProtocols
          : existing?.answeredLanProtocols ?? const [],
      server: device.server ?? existing?.server,
      pictogram: device.pictogram ?? existing?.pictogram,
      // The latest answer wins here rather than accumulating: these are what
      // the device answered on, and a device that has stopped answering SSDP
      // should stop claiming it. An empty set is not an answer, though — it
      // is a sighting that recorded none — so it leaves the last one standing.
      sources: device.sources.isNotEmpty
          ? device.sources
          : existing?.sources ?? const {},
      txt: _mergeTxt(existing?.txt, device.txt),
      category: category ?? existing?.category,
      specKey: specKey ?? existing?.specKey,
    );
    await save(record);
    return record;
  }

  /// The saved record [device] is another sighting of, if there is one.
  ///
  /// The id the sighting proposes is tried first, and is usually the answer.
  /// The fallbacks exist because the ladder [SavedNetworkDevice.stableIdFor]
  /// climbs depends on what the sighting carries: a robot filed under
  /// `mac:…` (read out of its TXT) is proposed as `hn:…` by the next sighting
  /// over a transport with no TXT at all, and the record it belongs to would
  /// never be found. Only rungs that identify the DEVICE are matched —
  /// hostname, or a name at the same address — never the address alone,
  /// which a DHCP lease hands to a different device altogether.
  SavedNetworkDevice? _existingFor(NetworkDevice device) {
    final byId = state
        .where((d) => d.id == SavedNetworkDevice.stableIdFor(device))
        .firstOrNull;
    if (byId != null) return byId;
    final hostname = device.hostname;
    if (hostname != null && hostname.isNotEmpty) {
      final byHostname = state.where((d) => d.hostname == hostname).firstOrNull;
      if (byHostname != null) return byHostname;
    }
    final name = device.displayName;
    return state
        .where(
            (d) => d.host == device.host && d.name == name && name.isNotEmpty)
        .firstOrNull;
  }

  /// The cached TXT map after [sighting] is folded into [existing].
  ///
  /// A key the sighting does not carry survives, because the transport it
  /// answered over may simply have no TXT to give. A key it carries EMPTY
  /// also leaves the established value alone: a TXT record may hold a bare
  /// flag with no value, which the parser stores as `''`, and an empty `blid`
  /// or `mac` is not an identity — it is the absence of one wearing the
  /// shape of a key.
  static Map<String, String> _mergeTxt(
    Map<String, String>? existing,
    Map<String, String> sighting,
  ) {
    final merged = {...?existing};
    for (final entry in sighting.entries) {
      if (entry.value.isEmpty && (merged[entry.key]?.isNotEmpty ?? false)) {
        continue;
      }
      merged[entry.key] = entry.value;
    }
    return merged;
  }

  bool contains(String id) => state.any((d) => d.id == id);
}

final savedNetworkDevicesProvider = StateNotifierProvider<
    SavedNetworkDevicesNotifier, List<SavedNetworkDevice>>(
  (ref) =>
      SavedNetworkDevicesNotifier(ref.watch(savedNetworkDeviceStoreProvider)),
);
