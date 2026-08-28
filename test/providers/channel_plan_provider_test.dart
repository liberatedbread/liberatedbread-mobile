// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/providers/channel_plan_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

RadioChannel _channel(String name, int rxHz) =>
    RadioChannel(name: name, rxFreqHz: rxHz, txFreqHz: rxHz);

List<RadioChannel> _channels(int count) => [
      for (var i = 0; i < count; i++) _channel('CH$i', 146000000 + i * 25000),
    ];

/// A tiny radio, so capacity is reachable in a test.
const _small = RadioProfile(
  id: 'test-small',
  displayName: 'Small',
  rxRanges: [FreqRange(136000000, 174000000)],
  factoryTxRanges: [FreqRange(144000000, 148000000)],
  channelCapacity: 4,
  nameLength: 5,
  programmingFamily: ProgrammingFamily.serialUv5r,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('starts with no plans', () async {
    final c = await container();
    expect(c.read(channelPlansProvider), isEmpty);
  });

  test('creates a plan with a unique id', () async {
    final c = await container();
    final notifier = c.read(channelPlansProvider.notifier);

    final first =
        await notifier.create(name: 'A', radioProfileId: 'uv-5r-mini');
    final second =
        await notifier.create(name: 'B', radioProfileId: 'uv-5r-mini');

    expect(first.id, isNot(second.id));
    expect(c.read(channelPlansProvider), hasLength(2));
    expect(notifier.byId(first.id)!.name, 'A');
    expect(notifier.byId('nope'), isNull);
  });

  test('renames and removes', () async {
    final c = await container();
    final notifier = c.read(channelPlansProvider.notifier);
    final plan = await notifier.create(name: 'A', radioProfileId: 'uv5r');

    await notifier.rename(plan.id, 'Renamed');
    expect(notifier.byId(plan.id)!.name, 'Renamed');

    await notifier.remove(plan.id);
    expect(c.read(channelPlansProvider), isEmpty);
    // Renaming something gone is a no-op, not a crash.
    await notifier.rename(plan.id, 'Ghost');
  });

  group('appending', () {
    test('adds channels and reports what it did', () async {
      final c = await container();
      final notifier = c.read(channelPlansProvider.notifier);
      final plan = await notifier.create(name: 'A', radioProfileId: 'uv5r');

      final outcome = await notifier
          .appendChannels(plan.id, _channels(3), profile: _small);

      expect(outcome.added, 3);
      expect(outcome.rejected, 0);
      expect(outcome.hitCapacity, isFalse);
      expect(notifier.byId(plan.id)!.channels, hasLength(3));
    });

    test('stops at capacity and says how many did not fit', () async {
      // The interesting case: forty ticked, thirty-two fit. Silently dropping
      // eight would be the worst possible answer.
      final c = await container();
      final notifier = c.read(channelPlansProvider.notifier);
      final plan = await notifier.create(name: 'A', radioProfileId: 'uv5r');

      final outcome = await notifier
          .appendChannels(plan.id, _channels(7), profile: _small);

      expect(outcome.added, 4);
      expect(outcome.rejected, 3);
      expect(outcome.hitCapacity, isTrue);
      expect(outcome.capacity, 4);
      expect(notifier.byId(plan.id)!.channels, hasLength(4));
    });

    test('a full plan accepts nothing more', () async {
      final c = await container();
      final notifier = c.read(channelPlansProvider.notifier);
      final plan = await notifier.create(name: 'A', radioProfileId: 'uv5r');
      await notifier.appendChannels(plan.id, _channels(4), profile: _small);

      final outcome = await notifier
          .appendChannels(plan.id, _channels(2), profile: _small);

      expect(outcome.added, 0);
      expect(outcome.rejected, 2);
      expect(notifier.byId(plan.id)!.channels, hasLength(4));
    });

    test('clamps names to what the radio can hold', () async {
      // A name the radio truncates is cosmetic; one that overruns the next
      // channel's record is not. Clamping here means the editor shows what
      // will actually land on the radio.
      final c = await container();
      final notifier = c.read(channelPlansProvider.notifier);
      final plan = await notifier.create(name: 'A', radioProfileId: 'uv5r');

      await notifier.appendChannels(
        plan.id,
        [_channel('WAY-TOO-LONG', 146940000)],
        profile: _small,
      );

      expect(notifier.byId(plan.id)!.channels.single.name, 'WAY-T');
      expect(notifier.byId(plan.id)!.channels.single.name.length,
          _small.nameLength);
    });

    test('the unlock mark sticks once set', () async {
      // The plan contains channels that need the unlock. A later ordinary
      // append does not make that untrue.
      final c = await container();
      final notifier = c.read(channelPlansProvider.notifier);
      final plan = await notifier.create(name: 'A', radioProfileId: 'uv5r');

      await notifier.appendChannels(plan.id, _channels(1),
          profile: _small, builtWithTxUnlock: true);
      expect(notifier.byId(plan.id)!.builtWithTxUnlock, isTrue);

      await notifier.appendChannels(plan.id, _channels(1), profile: _small);
      expect(notifier.byId(plan.id)!.builtWithTxUnlock, isTrue);
    });

    test('appending to a plan that is gone is a no-op', () async {
      final c = await container();
      final notifier = c.read(channelPlansProvider.notifier);
      final outcome = await notifier
          .appendChannels('ghost', _channels(2), profile: _small);
      expect(outcome.added, 0);
    });
  });

  group('editing', () {
    Future<({ProviderContainer c, ChannelPlansNotifier n, String id})>
        withFour() async {
      final c = await container();
      final n = c.read(channelPlansProvider.notifier);
      final plan = await n.create(name: 'A', radioProfileId: 'uv5r');
      await n.appendChannels(plan.id, _channels(4), profile: _small);
      return (c: c, n: n, id: plan.id);
    }

    test('removes one slot', () async {
      final s = await withFour();
      await s.n.removeAt(s.id, 1);
      expect([for (final ch in s.n.byId(s.id)!.channels) ch.name],
          ['CH0', 'CH2', 'CH3']);
    });

    test('ignores an out-of-range removal', () async {
      final s = await withFour();
      await s.n.removeAt(s.id, 99);
      await s.n.removeAt(s.id, -1);
      expect(s.n.byId(s.id)!.channels, hasLength(4));
    });

    test('removes several slots at once', () async {
      final s = await withFour();
      await s.n.removeMany(s.id, {0, 2});
      expect([for (final ch in s.n.byId(s.id)!.channels) ch.name],
          ['CH1', 'CH3']);
    });

    test('an empty multi-select removal changes nothing', () async {
      final s = await withFour();
      await s.n.removeMany(s.id, const {});
      expect(s.n.byId(s.id)!.channels, hasLength(4));
    });

    test('reorders as a plain move, because the list already adjusted',
        () async {
      // `ReorderableListView.onReorderItem` hands over the index the item
      // ends up at, having already accounted for it still being in the list
      // when the drop index was computed. Adjusting again here would send
      // every downward drag one slot short.
      final s = await withFour();
      await s.n.reorder(s.id, 0, 2);
      expect([for (final ch in s.n.byId(s.id)!.channels) ch.name],
          ['CH1', 'CH2', 'CH0', 'CH3']);

      await s.n.reorder(s.id, 3, 0);
      expect([for (final ch in s.n.byId(s.id)!.channels) ch.name],
          ['CH3', 'CH1', 'CH2', 'CH0']);
    });

    test('a reorder that goes nowhere changes nothing', () async {
      final s = await withFour();
      final before = s.n.byId(s.id)!.channels;
      await s.n.reorder(s.id, 1, 1);
      expect(s.n.byId(s.id)!.channels, before);
    });

    test('clamps a reorder to the ends of the list', () async {
      final s = await withFour();
      await s.n.reorder(s.id, 0, 99);
      expect(s.n.byId(s.id)!.channels.last.name, 'CH0');
      await s.n.reorder(s.id, 3, -5);
      expect(s.n.byId(s.id)!.channels.first.name, 'CH0');
      // Out-of-range sources are ignored rather than clamped: there is no
      // channel there to move.
      await s.n.reorder(s.id, 99, 0);
      expect(s.n.byId(s.id)!.channels.first.name, 'CH0');
    });

    test('updates a channel in place, clamping its name', () async {
      final s = await withFour();
      await s.n.updateChannel(
        s.id,
        1,
        _channel('RENAMED-LONG', 147000000),
        profile: _small,
      );
      final channel = s.n.byId(s.id)!.channels[1];
      expect(channel.name, 'RENAM');
      expect(channel.rxFreqHz, 147000000);
    });

    test('updates without a profile leave the name alone', () async {
      final s = await withFour();
      await s.n.updateChannel(s.id, 0, _channel('LONG-NAME', 146940000));
      expect(s.n.byId(s.id)!.channels.first.name, 'LONG-NAME');
    });

    test('replaceChannels takes what fits and clamps names', () async {
      // What a read from the radio produces.
      final s = await withFour();
      await s.n.replaceChannels(
        s.id,
        [for (var i = 0; i < 9; i++) _channel('FROMRADIO$i', 145000000 + i)],
        profile: _small,
      );
      final channels = s.n.byId(s.id)!.channels;
      expect(channels, hasLength(4));
      expect(channels.first.name, 'FROMR');
    });

    test('every edit stamps modifiedAt and floats the plan to the top',
        () async {
      final c = await container();
      final n = c.read(channelPlansProvider.notifier);
      final first = await n.create(name: 'First', radioProfileId: 'uv5r');
      await n.create(name: 'Second', radioProfileId: 'uv5r');
      expect(c.read(channelPlansProvider).first.name, 'Second');

      await n.rename(first.id, 'Touched');
      expect(c.read(channelPlansProvider).first.id, first.id);
      expect(n.byId(first.id)!.modifiedAt.isAfter(first.modifiedAt), isTrue);
    });
  });

  test('plans survive a new container over the same preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final first = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    final plan = await first
        .read(channelPlansProvider.notifier)
        .create(name: 'Persisted', radioProfileId: 'uv-5r-mini');
    await first
        .read(channelPlansProvider.notifier)
        .appendChannels(plan.id, _channels(2), profile: _small);
    first.dispose();

    final second = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(second.dispose);
    expect(second.read(channelPlansProvider), hasLength(1));
    expect(second.read(channelPlansProvider).single.channels, hasLength(2));
  });

  group('clampChannelName', () {
    test('leaves a short name alone', () {
      final channel = _channel('OK', 146940000);
      expect(clampChannelName(channel, _small), same(channel));
    });

    test('trims a long one', () {
      expect(clampChannelName(_channel('TOOLONGNAME', 146940000), _small).name,
          'TOOLO');
    });
  });
}
