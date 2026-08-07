// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/spec_choice_store.dart';
import 'saved_device_provider.dart' show sharedPreferencesProvider;

final specChoiceStoreProvider = Provider<SpecChoiceStore>(
  (ref) => SpecChoiceStore(ref.watch(sharedPreferencesProvider)),
);

/// The user's per-device spec choices, held in memory after the initial read.
///
/// Watched by the match provider, so saving a choice recomputes the match and
/// swaps the chooser prompt for typed controls in place.
class SpecChoicesNotifier extends StateNotifier<Map<String, String>> {
  final SpecChoiceStore _store;

  SpecChoicesNotifier(this._store) : super(_store.load());

  Future<void> choose(String deviceId, String specKey) async {
    state = await _store.save(deviceId, specKey);
  }

  Future<void> clear(String deviceId) async {
    state = await _store.remove(deviceId);
  }
}

final specChoicesProvider =
    StateNotifierProvider<SpecChoicesNotifier, Map<String, String>>(
  (ref) => SpecChoicesNotifier(ref.watch(specChoiceStoreProvider)),
);
