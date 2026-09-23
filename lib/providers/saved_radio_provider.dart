// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/radio_target.dart';
import '../services/saved_radio_store.dart';
import 'saved_device_provider.dart' show sharedPreferencesProvider;

final savedRadioStoreProvider = Provider<SavedRadioStore>(
  (ref) => SavedRadioStore(ref.watch(sharedPreferencesProvider)),
);

/// The radios the user has connected to, newest-first.
class SavedRadiosNotifier extends StateNotifier<List<SavedRadio>> {
  final SavedRadioStore _store;

  SavedRadiosNotifier(this._store) : super(_store.load());

  /// Records that [target] answered, refreshing its name and last-seen stamp.
  ///
  /// Merges into any existing record: a null [radioProfileId] keeps the model
  /// chosen last time rather than forgetting it, because a reconnect that
  /// did not involve the picker has said nothing about which model this is.
  Future<void> touch({
    required RadioTarget target,
    required DateTime seenAt,
    String? radioProfileId,
  }) async {
    final existing = savedRadioFor(target);
    state = await _store.save(SavedRadio(
      transport: target.transport,
      id: target.id,
      name: target.name.trim().isNotEmpty
          ? target.name
          : (existing?.name ?? target.name),
      lastSeen: seenAt,
      radioProfileId: radioProfileId ?? existing?.radioProfileId,
    ));
  }

  Future<void> remove(RadioTarget target) async {
    state = await _store.remove(target);
  }

  SavedRadio? savedRadioFor(RadioTarget target) => state
      .where((r) => r.transport == target.transport && r.id == target.id)
      .firstOrNull;

  bool contains(RadioTarget target) => savedRadioFor(target) != null;
}

final savedRadiosProvider =
    StateNotifierProvider<SavedRadiosNotifier, List<SavedRadio>>(
  (ref) => SavedRadiosNotifier(ref.watch(savedRadioStoreProvider)),
);
