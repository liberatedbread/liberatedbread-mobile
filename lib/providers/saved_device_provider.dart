// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/saved_device_store.dart';

/// Overridden in `main()` (and in tests) with an already-resolved instance so
/// widgets never have to await preferences mid-build.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError(
    'sharedPreferencesProvider must be overridden before use',
  ),
);

final savedDeviceStoreProvider = Provider<SavedDeviceStore>(
  (ref) => SavedDeviceStore(ref.watch(sharedPreferencesProvider)),
);

/// The user's paired devices, newest-first.
///
/// Holds the list in memory after the initial read so the History section can
/// rebuild without touching disk on every scan tick.
class SavedDevicesNotifier extends StateNotifier<List<SavedDevice>> {
  final SavedDeviceStore _store;

  SavedDevicesNotifier(this._store) : super(_store.load());

  Future<void> save(SavedDevice device) async {
    state = await _store.save(device);
  }

  Future<void> remove(String id) async {
    state = await _store.remove(id);
  }

  /// Records a successful connection, refreshing the name and last-seen stamp
  /// so the History list orders by genuine recency. Merges into any existing
  /// record rather than replacing it — a plain replace would silently drop
  /// the category/specKey a previous connection recorded.
  Future<void> touch({
    required String id,
    required String name,
    required DateTime seenAt,
  }) {
    final existing = state.where((d) => d.id == id).firstOrNull;
    return save(existing?.copyWith(name: name, lastSeen: seenAt) ??
        SavedDevice(id: id, name: name, lastSeen: seenAt));
  }

  /// Records which spec a connected device matched, so grouping can classify
  /// the device later while it is out of range. Both fields are replaced
  /// together (not merged field-by-field): they describe one match, and
  /// keeping a stale category next to a fresh specKey would mislabel the
  /// device. No-op for devices that were never saved.
  Future<void> recordMatch({
    required String id,
    required String? category,
    required String specKey,
  }) async {
    final existing = state.where((d) => d.id == id).firstOrNull;
    if (existing == null) return;
    if (existing.category == category && existing.specKey == specKey) return;
    await save(SavedDevice(
      id: existing.id,
      name: existing.name,
      lastSeen: existing.lastSeen,
      category: category,
      specKey: specKey,
    ));
  }

  bool contains(String id) => state.any((d) => d.id == id);
}

final savedDevicesProvider =
    StateNotifierProvider<SavedDevicesNotifier, List<SavedDevice>>(
  (ref) => SavedDevicesNotifier(ref.watch(savedDeviceStoreProvider)),
);
