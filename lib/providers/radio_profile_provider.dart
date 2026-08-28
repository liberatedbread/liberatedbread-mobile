// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/radio_profile.dart';
import 'spec_pack_provider.dart';

/// The radio the user is working with.
final selectedRadioProfileProvider =
    AsyncNotifierProvider<SelectedRadioProfileNotifier, RadioProfile>(
  SelectedRadioProfileNotifier.new,
);

class SelectedRadioProfileNotifier extends AsyncNotifier<RadioProfile> {
  static const key = 'radio_selected_profile_v1';

  @override
  Future<RadioProfile> build() async {
    final store = await ref.watch(prefsSettingsStoreProvider.future);
    // A stored id can outlive the build that wrote it — a profile removed or
    // renamed upstream must fall back rather than leaving the Radio tab with
    // no radio selected at all.
    return radioProfileById(await store.read(key)) ?? defaultRadioProfile;
  }

  Future<void> select(RadioProfile profile) async {
    final store = await ref.read(prefsSettingsStoreProvider.future);
    await store.write(key, profile.id);
    state = AsyncData(profile);
  }
}

/// Which radios the operator has acknowledged a transmit-range unlock for.
///
/// Per profile, and off for every profile until explicitly turned on. Stored
/// as a map rather than a single flag because the acknowledgement is about a
/// specific radio's specific expanded ranges: agreeing to it for a Mini says
/// nothing about a UV-17R Plus.
final txUnlockProvider =
    AsyncNotifierProvider<TxUnlockNotifier, Map<String, bool>>(
  TxUnlockNotifier.new,
);

class TxUnlockNotifier extends AsyncNotifier<Map<String, bool>> {
  static const key = 'radio_tx_unlock_v1';

  @override
  Future<Map<String, bool>> build() async {
    final store = await ref.watch(prefsSettingsStoreProvider.future);
    final raw = await store.read(key);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is bool) entry.key: entry.value as bool,
      };
    } on FormatException catch (error) {
      // Unreadable means off, which is the safe direction: the worst outcome
      // is that the operator is asked to acknowledge again.
      Log.radio.debug('tx unlock settings unreadable', error: error);
      return const {};
    }
  }

  /// Whether the unlock is on for [profile].
  ///
  /// Always false for a radio with no documented software path, whatever is
  /// stored — a setting cannot grant a capability the radio does not have,
  /// and a stale `true` from a build that thought otherwise must not leak
  /// through.
  bool isEnabledFor(RadioProfile profile) {
    if (!profile.txUnlock.supported) return false;
    return state.value?[profile.id] ?? false;
  }

  Future<void> setEnabled(RadioProfile profile, bool enabled) async {
    if (!profile.txUnlock.supported && enabled) return;
    final store = await ref.read(prefsSettingsStoreProvider.future);
    final next = {...?state.value, profile.id: enabled};
    await store.write(key, jsonEncode(next));
    state = AsyncData(next);
  }
}

/// Whether the unlock is currently on for the selected radio.
///
/// A single boolean for the screens to watch, so no widget has to remember
/// that the stored map and the profile's own capability both have a say.
final txUnlockEnabledProvider = Provider<bool>((ref) {
  final profile = ref.watch(selectedRadioProfileProvider).value;
  final unlocks = ref.watch(txUnlockProvider).value;
  if (profile == null || unlocks == null) return false;
  if (!profile.txUnlock.supported) return false;
  return unlocks[profile.id] ?? false;
});
