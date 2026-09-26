// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/channel_plan.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../services/channel_plan_store.dart';
import 'saved_device_provider.dart' show sharedPreferencesProvider;

/// What happened when channels were appended to a plan.
///
/// A record rather than a bare count because the interesting case is the
/// partial one: the user ticked forty channels, the radio holds thirty-two,
/// and silently dropping eight of them would be the worst possible answer.
class AppendOutcome {
  final int added;
  final int rejected;

  /// The capacity that stopped it, when something was rejected.
  final int? capacity;

  const AppendOutcome({required this.added, this.rejected = 0, this.capacity});

  bool get hitCapacity => rejected > 0;
}

/// The plan store, over the SharedPreferences instance main() already
/// resolves and overrides — the same wiring [savedDeviceStoreProvider] and
/// [deviceGroupStoreProvider] use, rather than a second bootstrap of its own.
final channelPlanStoreProvider = Provider<ChannelPlanStore>(
  (ref) => ChannelPlanStore(ref.watch(sharedPreferencesProvider)),
);

final channelPlansProvider =
    StateNotifierProvider<ChannelPlansNotifier, List<ChannelPlan>>((ref) {
      return ChannelPlansNotifier(ref.watch(channelPlanStoreProvider));
    });

/// The user's plans, and every edit that can be made to one.
///
/// Modelled on [DeviceGroupsNotifier]: the store owns persistence and returns
/// the new list, the notifier owns ordering and identity. Every mutation
/// stamps `modifiedAt`, which is also the sort key -- so the plan you just
/// touched is the one at the top when you come back.
class ChannelPlansNotifier extends StateNotifier<List<ChannelPlan>> {
  final ChannelPlanStore _store;

  /// Tie-break for ids minted in the same microsecond, for the same reason
  /// [DeviceGroupsNotifier] has one: identical ids would make the second plan
  /// silently overwrite the first.
  static int _creationSeq = 0;

  ChannelPlansNotifier(this._store) : super(_store.load());

  ChannelPlan? byId(String id) {
    for (final plan in state) {
      if (plan.id == id) return plan;
    }
    return null;
  }

  Future<ChannelPlan> create({
    required String name,
    required String radioProfileId,
    List<RadioChannel> channels = const [],
    bool builtWithTxUnlock = false,
  }) async {
    final now = DateTime.now();
    final plan = ChannelPlan(
      id: 'plan${now.microsecondsSinceEpoch}-${_creationSeq++}',
      name: name,
      radioProfileId: radioProfileId,
      channels: channels,
      builtWithTxUnlock: builtWithTxUnlock,
      createdAt: now,
      modifiedAt: now,
    );
    state = await _store.save(plan);
    return plan;
  }

  Future<void> rename(String id, String name) async {
    final plan = byId(id);
    if (plan == null) return;
    await _replace(plan.copyWith(name: name));
  }

  Future<void> remove(String id) async {
    state = await _store.remove(id);
  }

  /// Append [channels], stopping at the radio's capacity.
  ///
  /// Names are clamped to what the radio's display and codeplug hold. A name
  /// the radio would truncate is cosmetic; one that overruns the next
  /// channel's record is not, and the clamp happens here rather than at write
  /// time so what the user sees in the editor is what lands on the radio.
  Future<AppendOutcome> appendChannels(
    String id,
    List<RadioChannel> channels, {
    required RadioProfile profile,
    bool builtWithTxUnlock = false,
  }) async {
    final plan = byId(id);
    if (plan == null) return const AppendOutcome(added: 0);

    final room = profile.channelCapacity - plan.channels.length;
    if (room <= 0) {
      return AppendOutcome(
        added: 0,
        rejected: channels.length,
        capacity: profile.channelCapacity,
      );
    }

    final accepted = channels.take(room).toList();
    final rejected = channels.length - accepted.length;

    await _replace(
      plan.copyWith(
        channels: [
          ...plan.channels,
          for (final channel in accepted) clampChannelName(channel, profile),
        ],
        // Once true, it stays true: the plan contains channels that need the
        // unlock, and a later ordinary append does not make that untrue.
        builtWithTxUnlock: plan.builtWithTxUnlock || builtWithTxUnlock,
      ),
    );

    return AppendOutcome(
      added: accepted.length,
      rejected: rejected,
      capacity: rejected > 0 ? profile.channelCapacity : null,
    );
  }

  Future<void> removeAt(String id, int index) async {
    final plan = byId(id);
    if (plan == null || index < 0 || index >= plan.channels.length) return;
    final channels = [...plan.channels]..removeAt(index);
    await _replace(plan.copyWith(channels: channels));
  }

  /// Remove several slots at once — what multi-select delete runs.
  Future<void> removeMany(String id, Set<int> indices) async {
    final plan = byId(id);
    if (plan == null || indices.isEmpty) return;
    final channels = <RadioChannel>[];
    for (var i = 0; i < plan.channels.length; i++) {
      if (!indices.contains(i)) channels.add(plan.channels[i]);
    }
    if (channels.length == plan.channels.length) return;
    await _replace(plan.copyWith(channels: channels));
  }

  /// Move the channel at [from] to sit at index [to].
  ///
  /// A plain move: [to] is where the channel ends up, not where the list said
  /// to drop it. `ReorderableListView.onReorderItem` already adjusts for the
  /// item still being in the list when the index is computed, so doing it
  /// again here would send every downward drag one slot short.
  Future<void> reorder(String id, int from, int to) async {
    final plan = byId(id);
    if (plan == null) return;
    if (from < 0 || from >= plan.channels.length) return;

    var target = to;
    if (target < 0) target = 0;
    if (target >= plan.channels.length) target = plan.channels.length - 1;
    if (target == from) return;

    final channels = [...plan.channels];
    channels.insert(target, channels.removeAt(from));
    await _replace(plan.copyWith(channels: channels));
  }

  Future<void> updateChannel(
    String id,
    int index,
    RadioChannel channel, {
    RadioProfile? profile,
  }) async {
    final plan = byId(id);
    if (plan == null || index < 0 || index >= plan.channels.length) return;
    final channels = [...plan.channels];
    channels[index] = profile == null
        ? channel
        : clampChannelName(channel, profile);
    await _replace(plan.copyWith(channels: channels));
  }

  /// Replace every channel — what a read from the radio produces.
  Future<void> replaceChannels(
    String id,
    List<RadioChannel> channels, {
    required RadioProfile profile,
  }) async {
    final plan = byId(id);
    if (plan == null) return;
    await _replace(
      plan.copyWith(
        channels: [
          for (final channel in channels.take(profile.channelCapacity))
            clampChannelName(channel, profile),
        ],
      ),
    );
  }

  Future<void> _replace(ChannelPlan plan) async {
    state = await _store.save(plan.copyWith(modifiedAt: DateTime.now()));
  }
}

/// Trim a channel's name to what [profile] can hold.
RadioChannel clampChannelName(RadioChannel channel, RadioProfile profile) {
  if (channel.name.length <= profile.nameLength) return channel;
  return channel.copyWith(name: channel.name.substring(0, profile.nameLength));
}
