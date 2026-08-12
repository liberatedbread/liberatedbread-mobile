// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The per-light card: honest unknowns, one write per slider gesture, and a
// drag value that holds until the device answers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/hub_child_light_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('shows the light and toggles through the callback',
      (tester) async {
    final toggles = <bool>[];
    await tester.pumpWidget(_wrap(HubChildLightCard(
      label: 'Kitchen counter',
      isOn: true,
      brightness: 254,
      onToggle: toggles.add,
      onBrightness: (_) {},
    )));

    expect(find.text('Kitchen counter'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    expect(toggles, [false], reason: 'an on light toggles off');
  });

  testWidgets('an unknown state says so instead of inventing off',
      (tester) async {
    await tester.pumpWidget(_wrap(HubChildLightCard(
      label: 'Hallway',
      isOn: null,
      brightness: null,
      onToggle: (_) {},
      onBrightness: (_) {},
    )));

    expect(find.text('State unknown'), findsOneWidget);
    // The switch renders (off-looking) but stays usable — the user can still
    // command a light whose reading was missing.
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
  });

  testWidgets('the slider commits once, on gesture end, rounded',
      (tester) async {
    final commits = <double>[];
    await tester.pumpWidget(_wrap(HubChildLightCard(
      label: 'Desk',
      isOn: true,
      brightness: 100,
      onToggle: (_) {},
      onBrightness: commits.add,
    )));

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();

    expect(commits, hasLength(1),
        reason: 'one write per gesture is what keeps a throttling bridge '
            'happy — never one per drag pixel');
    expect(commits.single, commits.single.roundToDouble());
    expect(commits.single, inInclusiveRange(1, 254));
  });

  testWidgets('busy disables the controls and shows progress', (tester) async {
    await tester.pumpWidget(_wrap(HubChildLightCard(
      label: 'Desk',
      isOn: false,
      brightness: 50,
      busy: true,
      onToggle: (_) {},
      onBrightness: (_) {},
    )));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
  });

  testWidgets('no brightness action means no slider', (tester) async {
    await tester.pumpWidget(_wrap(HubChildLightCard(
      label: 'Plain bulb',
      isOn: true,
      brightness: null,
      onToggle: (_) {},
    )));
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('a fresh reading takes the slider back from the drag',
      (tester) async {
    Widget at(double brightness) => _wrap(HubChildLightCard(
          label: 'Desk',
          isOn: true,
          brightness: brightness,
          onToggle: (_) {},
          onBrightness: (_) {},
        ));

    await tester.pumpWidget(at(100));
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();
    final dragged = tester.widget<Slider>(find.byType(Slider)).value;
    expect(dragged, isNot(100));

    // The re-read after the write answers with the device's own value.
    await tester.pumpWidget(at(200));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 200);
  });
}
