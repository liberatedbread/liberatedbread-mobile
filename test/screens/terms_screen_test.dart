// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-051: the "Independent and unofficial" heading sat beside its icon as a
// bare Text, so at accessibility text sizes on a narrow phone it overflowed
// the row of the first screen anyone sees.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/screens/terms_screen.dart';

void main() {
  testWidgets('renders without overflow at 320 pt and 3x text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(3.0)),
            child: TermsScreen(onAccept: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The list is lazy and at 3x the heading is below the fold; only a built
    // Row can overflow, so scroll until it is.
    await tester.scrollUntilVisible(
      find.text('Independent and unofficial'),
      200,
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Independent and unofficial'), findsOneWidget);
  });
}
