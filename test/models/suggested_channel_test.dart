// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';

void main() {
  const repeater = RadioChannel(
    name: 'W1AW',
    rxFreqHz: 146940000,
    txFreqHz: 146340000,
    txTone: ToneSetting.ctcss(1000),
  );

  test('every category has a label a person can read', () {
    for (final category in SuggestionCategory.values) {
      expect(category.label, isNotEmpty);
    }
    expect(SuggestionCategory.weather.label, 'Weather');
  });

  test('a transmittable suggestion goes into a plan unchanged', () {
    const suggestion = SuggestedChannel(
      channel: repeater,
      category: SuggestionCategory.repeater,
      sourceId: 'repeaterbook',
    );
    expect(suggestion.channelForPlan, repeater);
  });

  test('a listen-only suggestion becomes a receive-only channel', () {
    // The transmit frequency is pulled back onto the receive frequency as
    // well as the flag being set: a radio that ignores the flag can then only
    // key on the frequency it is already listening to.
    const suggestion = SuggestedChannel(
      channel: repeater,
      category: SuggestionCategory.repeater,
      sourceId: 'repeaterbook',
      txAllowed: false,
    );
    final planned = suggestion.channelForPlan;
    expect(planned.rxOnly, isTrue);
    expect(planned.txFreqHz, repeater.rxFreqHz);
    expect(planned.rxFreqHz, repeater.rxFreqHz);
  });

  test('dedupe key matches two listings of the same repeater', () {
    const fromRepeaterBook = SuggestedChannel(
      channel: repeater,
      category: SuggestionCategory.repeater,
      sourceId: 'repeaterbook',
      distanceKm: 12.0,
    );
    const fromMyGmrs = SuggestedChannel(
      // Same machine, different name and different source.
      channel: RadioChannel(
        name: 'Newington',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.ctcss(1000),
      ),
      category: SuggestionCategory.repeater,
      sourceId: 'mygmrs',
      distanceKm: 12.4,
    );
    expect(fromRepeaterBook.dedupeKey, fromMyGmrs.dedupeKey);
  });

  test('dedupe key separates repeaters that differ only by access tone', () {
    const withTone = SuggestedChannel(
      channel: repeater,
      category: SuggestionCategory.repeater,
      sourceId: 'a',
    );
    const withoutTone = SuggestedChannel(
      channel: RadioChannel(
        name: 'W1AW',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
      ),
      category: SuggestionCategory.repeater,
      sourceId: 'b',
    );
    expect(withTone.dedupeKey, isNot(withoutTone.dedupeKey));
  });

  test('copyWith carries provenance across a capability decision', () {
    const suggestion = SuggestedChannel(
      channel: repeater,
      category: SuggestionCategory.repeater,
      sourceId: 'repeaterbook',
      distanceKm: 8.5,
      callsign: 'W1AW',
      details: 'Newington, CT',
    );
    final badged = suggestion.copyWith(requiresTxUnlock: true);
    expect(badged.sourceId, 'repeaterbook');
    expect(badged.distanceKm, 8.5);
    expect(badged.callsign, 'W1AW');
    expect(badged.details, 'Newington, CT');
    expect(badged.requiresTxUnlock, isTrue);
    expect(badged.txAllowed, isTrue);
  });
}
