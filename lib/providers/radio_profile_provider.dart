// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/radio_band_limits.dart';
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
    // Waited for rather than read off [state]: a caller that never watched
    // this provider can arrive while it is still loading, and a map built
    // from nothing would overwrite every other radio's setting.
    final current = await future;
    final store = await ref.read(prefsSettingsStoreProvider.future);
    final next = {...current, profile.id: enabled};
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
  ref.watch(txUnlockProvider);
  if (profile == null) return false;
  return ref.read(txUnlockProvider.notifier).isEnabledFor(profile);
});

/// The transmit limits each model had before this app first widened one, by
/// profile id: what "put back" writes.
///
/// Kept on this device and never overwritten: a radio read after it was
/// widened holds widened limits, and those are not the ones to go back to.
final originalBandLimitsProvider =
    AsyncNotifierProvider<
      OriginalBandLimitsNotifier,
      Map<String, OriginalBandLimits>
    >(OriginalBandLimitsNotifier.new);

class OriginalBandLimitsNotifier
    extends AsyncNotifier<Map<String, OriginalBandLimits>> {
  static const key = 'radio_original_limits_v1';

  @override
  Future<Map<String, OriginalBandLimits>> build() async {
    final store = await ref.watch(prefsSettingsStoreProvider.future);
    final raw = await store.read(key);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      return {
        for (final entry in decoded.entries)
          entry.key: ?OriginalBandLimits.fromJson(entry.value),
      };
    } on FormatException catch (error) {
      // Worth more than a debug line: these are the only record of what the
      // radio held, and losing them loses the way back short of a restore.
      Log.radio.warning('recorded band limits unreadable', error: error);
      return const {};
    }
  }

  /// Record [limits] as what [profile] radios came with, unless something is
  /// recorded for it already. Returns what is recorded afterwards.
  Future<OriginalBandLimits> recordIfAbsent(
    RadioProfile profile,
    OriginalBandLimits limits,
  ) async {
    final current = await future;
    final existing = current[profile.id];
    if (existing != null) return existing;
    final store = await ref.read(prefsSettingsStoreProvider.future);
    final next = {...current, profile.id: limits};
    await store.write(
      key,
      jsonEncode({
        for (final entry in next.entries) entry.key: entry.value.toJson(),
      }),
    );
    state = AsyncData(next);
    return limits;
  }
}
