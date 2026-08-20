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
  /// caller knows them; an existing record's match survives a sighting that
  /// carries none (`??`-merge), because a re-open through a stale match
  /// list must not unclassify a TV.
  Future<SavedNetworkDevice> touch(
    NetworkDevice device, {
    String? category,
    String? specKey,
    DateTime? seenAt,
  }) async {
    final id = SavedNetworkDevice.stableIdFor(device);
    final existing = state.where((d) => d.id == id).firstOrNull;
    final record = SavedNetworkDevice(
      id: id,
      name: device.displayName,
      lastSeen: seenAt ?? DateTime.now(),
      host: device.host,
      hostname: device.hostname,
      port: device.port,
      ssdpPort: device.ssdpPort,
      ssdpDescriptionPath: device.ssdpDescriptionPath,
      ssdpTargets: device.ssdpTargets,
      category: category ?? existing?.category,
      specKey: specKey ?? existing?.specKey,
    );
    await save(record);
    return record;
  }

  bool contains(String id) => state.any((d) => d.id == id);
}

final savedNetworkDevicesProvider = StateNotifierProvider<
    SavedNetworkDevicesNotifier, List<SavedNetworkDevice>>(
  (ref) =>
      SavedNetworkDevicesNotifier(ref.watch(savedNetworkDeviceStoreProvider)),
);
