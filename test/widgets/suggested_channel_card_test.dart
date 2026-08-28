// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/widgets/suggested_channel_card.dart';

Future<bool?> _pump(
  WidgetTester tester,
  SuggestedChannel suggestion, {
  bool selected = false,
}) async {
  bool? toggled;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SuggestedChannelTile(
        suggestion: suggestion,
        selected: selected,
        onSelected: (value) => toggled = value,
      ),
    ),
  ));
  return toggled;
}

const _repeater = SuggestedChannel(
  channel: RadioChannel(
    name: 'W1AW',
    rxFreqHz: 146940000,
    txFreqHz: 146340000,
    txTone: ToneSetting.ctcss(1000),
  ),
  category: SuggestionCategory.repeater,
  sourceId: 'repeaterbook',
  distanceKm: 8.4,
  callsign: 'W1AW',
  details: 'Testington · Hartford County',
);

void main() {
  testWidgets('shows the name, frequency and how far away it is',
      (tester) async {
    await _pump(tester, _repeater);
    expect(find.text('W1AW'), findsOneWidget);
    expect(find.text('146.940 MHz'), findsOneWidget);
    expect(find.textContaining('8.4 km'), findsOneWidget);
  });

  testWidgets('shows the offset and the access tone', (tester) async {
    await _pump(tester, _repeater);
    expect(find.textContaining('−0.600 MHz'), findsOneWidget);
    expect(find.textContaining('tone 100.0'), findsOneWidget);
  });

  testWidgets('shows the source details verbatim', (tester) async {
    await _pump(tester, _repeater);
    expect(find.text('Testington · Hartford County'), findsOneWidget);
  });

  testWidgets('rounds distant repeaters to whole km', (tester) async {
    await _pump(
      tester,
      const SuggestedChannel(
        channel: RadioChannel(
            name: 'FAR', rxFreqHz: 146940000, txFreqHz: 146340000),
        category: SuggestionCategory.repeater,
        sourceId: 'x',
        distanceKm: 42.7,
      ),
    );
    expect(find.textContaining('43 km'), findsOneWidget);
  });

  testWidgets('badges a listen-only suggestion', (tester) async {
    // Without this, a repeater the radio cannot key looks exactly like one it
    // can -- and the person ticking the box is the one who needs to know.
    await _pump(
      tester,
      const SuggestedChannel(
        channel: RadioChannel(
            name: 'PUBLIC', rxFreqHz: 155000000, txFreqHz: 155000000),
        category: SuggestionCategory.repeater,
        sourceId: 'x',
        txAllowed: false,
      ),
    );
    expect(find.text('Listen only'), findsOneWidget);
    expect(find.text('Needs widened range'), findsNothing);
  });

  testWidgets('badges one that needs the widened range', (tester) async {
    await _pump(
      tester,
      const SuggestedChannel(
        channel: RadioChannel(
            name: 'MARS', rxFreqHz: 140000000, txFreqHz: 140000000),
        category: SuggestionCategory.repeater,
        sourceId: 'x',
        requiresTxUnlock: true,
      ),
    );
    expect(find.text('Needs widened range'), findsOneWidget);
    expect(find.text('Listen only'), findsNothing);
  });

  testWidgets('an ordinary suggestion carries no badges', (tester) async {
    await _pump(tester, _repeater);
    expect(find.text('Listen only'), findsNothing);
    expect(find.text('Needs widened range'), findsNothing);
  });

  testWidgets('describes a simplex channel as simplex', (tester) async {
    await _pump(
      tester,
      const SuggestedChannel(
        channel: RadioChannel(
            name: '2m Call', rxFreqHz: 146520000, txFreqHz: 146520000),
        category: SuggestionCategory.preset,
        sourceId: 'bundled',
      ),
    );
    expect(find.textContaining('simplex'), findsOneWidget);
  });

  testWidgets('reports a tick and an untick', (tester) async {
    expect(await _pump(tester, _repeater), isNull);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    // Pumped again to read the callback value out of the closure.
    bool? toggled;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SuggestedChannelTile(
          suggestion: _repeater,
          selected: false,
          onSelected: (value) => toggled = value,
        ),
      ),
    ));
    await tester.tap(find.byType(CheckboxListTile));
    expect(toggled, isTrue);
  });

  testWidgets('renders as selected when it is', (tester) async {
    await _pump(tester, _repeater, selected: true);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue);
  });
}
