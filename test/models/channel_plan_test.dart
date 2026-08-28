// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';

ChannelPlan _plan({
  List<RadioChannel> channels = const [],
  bool unlock = false,
}) =>
    ChannelPlan(
      id: 'p1',
      name: 'Local repeaters',
      radioProfileId: 'uv-5r-mini',
      channels: channels,
      builtWithTxUnlock: unlock,
      createdAt: DateTime.utc(2026, 8, 1, 12),
      modifiedAt: DateTime.utc(2026, 8, 2, 9, 30),
    );

void main() {
  const channel = RadioChannel(
    name: 'W1AW',
    rxFreqHz: 146940000,
    txFreqHz: 146340000,
    txTone: ToneSetting.ctcss(1000),
  );

  test('round-trips through JSON', () {
    final plan = _plan(channels: const [channel], unlock: true);
    final decoded = ChannelPlan.fromJson(
        jsonDecode(jsonEncode(plan.toJson())) as Map<String, dynamic>);
    expect(decoded, isNotNull);
    expect(decoded!.id, plan.id);
    expect(decoded.name, plan.name);
    expect(decoded.radioProfileId, plan.radioProfileId);
    expect(decoded.channels, plan.channels);
    expect(decoded.builtWithTxUnlock, isTrue);
    expect(decoded.createdAt, plan.createdAt);
    expect(decoded.modifiedAt, plan.modifiedAt);
  });

  test('an empty plan survives the round trip as an empty plan', () {
    final decoded = ChannelPlan.fromJson(
        jsonDecode(jsonEncode(_plan().toJson())) as Map<String, dynamic>);
    expect(decoded!.isEmpty, isTrue);
    expect(decoded.length, 0);
    expect(decoded.builtWithTxUnlock, isFalse);
  });

  test('channel order is preserved — the order IS the slot numbering', () {
    final channels = [
      for (var i = 0; i < 8; i++)
        RadioChannel(
          name: 'CH$i',
          rxFreqHz: 145000000 + i * 25000,
          txFreqHz: 145000000 + i * 25000,
        ),
    ];
    final decoded = ChannelPlan.fromJson(
        jsonDecode(jsonEncode(_plan(channels: channels).toJson()))
            as Map<String, dynamic>);
    expect([for (final c in decoded!.channels) c.name],
        [for (final c in channels) c.name]);
  });

  test('rejects a record with no identity', () {
    expect(ChannelPlan.fromJson(const {}), isNull);
    expect(ChannelPlan.fromJson(const {'id': '', 'name': 'x'}), isNull);
    expect(ChannelPlan.fromJson(const {'id': 'p', 'name': 'x'}), isNull); // no
    // profile id: a plan that does not know which radio it targets cannot be
    // capacity-checked or written.
    expect(
        ChannelPlan.fromJson(
            const {'id': 'p', 'name': 'x', 'radioProfileId': ''}),
        isNull);
  });

  test('one corrupt channel costs its slot, not the plan', () {
    // This is the trade the store makes deliberately: a plan is minutes of
    // someone's work, and losing all of it to one bad record is worse than
    // losing the record.
    final decoded = ChannelPlan.fromJson({
      'id': 'p1',
      'name': 'Mixed',
      'radioProfileId': 'uv-5r-mini',
      'channels': [
        channel.toJson(),
        {'name': 'broken'},
        'not even a map',
        {'name': 'ok', 'rx': 146520000},
      ],
    });
    expect(decoded, isNotNull);
    expect(decoded!.channels.length, 2);
    expect(decoded.channels.first.name, 'W1AW');
    expect(decoded.channels.last.name, 'ok');
  });

  test('a missing channels list reads as an empty plan', () {
    final decoded = ChannelPlan.fromJson(
        const {'id': 'p', 'name': 'x', 'radioProfileId': 'uv5r'});
    expect(decoded, isNotNull);
    expect(decoded!.channels, isEmpty);
  });

  test('unparseable timestamps fall back rather than dropping the plan', () {
    final decoded = ChannelPlan.fromJson(const {
      'id': 'p',
      'name': 'x',
      'radioProfileId': 'uv5r',
      'createdAt': 'last tuesday',
      'modifiedAt': 42,
    });
    expect(decoded, isNotNull);
    expect(decoded!.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
  });

  test('copyWith keeps identity and creation time', () {
    final plan = _plan(channels: const [channel]);
    final renamed = plan.copyWith(
      name: 'Renamed',
      modifiedAt: DateTime.utc(2026, 9),
    );
    expect(renamed.id, plan.id);
    expect(renamed.createdAt, plan.createdAt);
    expect(renamed.name, 'Renamed');
    expect(renamed.modifiedAt, DateTime.utc(2026, 9));
    expect(renamed.channels, plan.channels);
  });

  test('identity is the id, so a renamed plan is the same plan', () {
    final plan = _plan();
    expect(plan.copyWith(name: 'Other'), plan);
    expect(plan.copyWith(name: 'Other').hashCode, plan.hashCode);
  });
}
