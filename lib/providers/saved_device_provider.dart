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
  /// so the History list orders by genuine recency.
  Future<void> touch({
    required String id,
    required String name,
    required DateTime seenAt,
  }) =>
      save(SavedDevice(id: id, name: name, lastSeen: seenAt));

  bool contains(String id) => state.any((d) => d.id == id);
}

final savedDevicesProvider =
    StateNotifierProvider<SavedDevicesNotifier, List<SavedDevice>>(
  (ref) => SavedDevicesNotifier(ref.watch(savedDeviceStoreProvider)),
);
