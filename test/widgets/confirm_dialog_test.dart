// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/confirm_dialog.dart';

/// Opens the dialog from a button and records what it answered.
Future<List<bool>> _open(WidgetTester tester) async {
  final answers = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => answers.add(
            await confirmAction(
              context,
              title: 'Write to the radio?',
              message: 'Its channels are replaced.',
              confirmLabel: 'Write',
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return answers;
}

void main() {
  testWidgets('says what it asks, and yes only for the confirm button', (
    tester,
  ) async {
    final answers = await _open(tester);
    expect(find.text('Write to the radio?'), findsOneWidget);
    expect(find.text('Its channels are replaced.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Write'));
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('cancel is no', (tester) async {
    final answers = await _open(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  testWidgets('dismissing it is no', (tester) async {
    final answers = await _open(tester);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });
}
