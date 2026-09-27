// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/services/channel_plan_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = 'radio_channel_plans_v1';

ChannelPlan _plan(
  String id, {
  String name = 'Plan',
  List<RadioChannel> channels = const [],
  DateTime? modifiedAt,
}) => ChannelPlan(
  id: id,
  name: name,
  radioProfileId: 'uv-5r-mini',
  channels: channels,
  createdAt: DateTime.utc(2026, 8),
  modifiedAt: modifiedAt ?? DateTime.utc(2026, 8),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ChannelPlanStore> store([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return ChannelPlanStore(await SharedPreferences.getInstance());
  }

  test('starts empty', () async {
    expect((await store()).load(), isEmpty);
  });

  test('saves and reads back', () async {
    final s = await store();
    const channel = RadioChannel(
      name: 'W1AW',
      rxFreqHz: 146940000,
      txFreqHz: 146340000,
      txTone: ToneSetting.ctcss(1000),
    );
    await s.save(_plan('a', channels: const [channel]));

    final loaded = s.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.id, 'a');
    expect(loaded.single.channels.single, channel);
  });

  test('replaces a plan with the same id rather than duplicating it', () async {
    final s = await store();
    await s.save(_plan('a', name: 'First'));
    await s.save(_plan('a', name: 'Second'));

    expect(s.load(), hasLength(1));
    expect(s.load().single.name, 'Second');
  });

  test('sorts newest-modified first', () async {
    final s = await store();
    await s.save(_plan('old', modifiedAt: DateTime.utc(2026, 1)));
    await s.save(_plan('new', modifiedAt: DateTime.utc(2026, 8)));
    await s.save(_plan('mid', modifiedAt: DateTime.utc(2026, 4)));

    expect([for (final p in s.load()) p.id], ['new', 'mid', 'old']);
  });

  test('removes by id', () async {
    final s = await store();
    await s.save(_plan('a'));
    await s.save(_plan('b'));

    await s.remove('a');
    expect([for (final p in s.load()) p.id], ['b']);

    // Removing something that is not there is not an error.
    await s.remove('nope');
    expect(s.load(), hasLength(1));
  });

  test('one corrupt record costs itself, not the rest', () async {
    // A plan is minutes of somebody's work assembling channels. Losing all of
    // them to one bad record would be much worse than losing the record.
    final s = await store({
      _key: jsonEncode([
        _plan('good').toJson(),
        {'id': 'broken'},
        'not even a map',
        _plan('also-good').toJson(),
      ]),
    });
    expect([
      for (final p in s.load()) p.id,
    ], containsAll(['good', 'also-good']));
    expect(s.load(), hasLength(2));
  });

  test('an unreadable blob reads as no plans rather than throwing', () async {
    for (final corrupt in ['not json', '{}', '7']) {
      expect((await store({_key: corrupt})).load(), isEmpty, reason: corrupt);
    }
  });

  test('survives a round trip through the stored JSON', () async {
    final s = await store();
    await s.save(
      _plan(
        'a',
        channels: const [
          RadioChannel(name: 'A', rxFreqHz: 146940000, txFreqHz: 146340000),
          RadioChannel.receiveOnly(name: 'WX1', freqHz: 162550000),
        ],
      ),
    );

    final reloaded = ChannelPlanStore(
      await SharedPreferences.getInstance(),
    ).load();
    expect(reloaded.single.channels, hasLength(2));
    expect(reloaded.single.channels.last.rxOnly, isTrue);
  });
}
