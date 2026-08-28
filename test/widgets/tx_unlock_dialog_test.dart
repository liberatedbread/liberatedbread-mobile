// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/widgets/tx_unlock_dialog.dart';

/// Tick the acknowledgement, scrolling to it first. On a small screen it
/// sits below the fold inside the dialog's own scroll view, which is exactly
/// what a user has to do too.
Future<void> _acknowledge(WidgetTester tester) async {
  final checkbox = find.byType(CheckboxListTile);
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

/// Opens the dialog and records what it answered.
Future<bool?> _show(WidgetTester tester, RadioProfile profile) async {
  bool? answer;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await showTxUnlockDialog(context, profile);
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('a radio with no software path never gets asked', (tester) async {
    // Not hypothetical: the whole UV-17Pro family is like this. Its transmit
    // range lives in firmware, so there is nothing to acknowledge.
    expect(uv5rMiniProfile.txUnlock.supported, isFalse);
    await _show(tester, uv5rMiniProfile);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('names the ranges the radio would reach', (tester) async {
    await _show(tester, uv5rProfile);
    expect(find.byType(AlertDialog), findsOneWidget);
    // The expanded VHF span, in MHz, so the operator can see what they are
    // agreeing to rather than a word like "expanded".
    expect(find.textContaining('130.000'), findsOneWidget);
  });

  testWidgets('says who is responsible and what the ranges contain',
      (tester) async {
    await _show(tester, uv5rProfile);
    expect(find.textContaining('public safety'), findsOneWidget);
    expect(find.textContaining('solely responsible'), findsOneWidget);
    expect(find.textContaining('MARS'), findsOneWidget);
  });

  testWidgets('cannot be confirmed until the box is ticked', (tester) async {
    // A dialog whose confirm button works regardless is a dialog nobody read.
    await _show(tester, uv5rProfile);

    final enable = find.widgetWithText(FilledButton, 'Enable');
    expect(tester.widget<FilledButton>(enable).onPressed, isNull);

    await _acknowledge(tester);
    expect(tester.widget<FilledButton>(enable).onPressed, isNotNull);
  });

  testWidgets('confirming returns true', (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await showTxUnlockDialog(context, uv5rProfile);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _acknowledge(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Enable'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('cancelling leaves it off', (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await showTxUnlockDialog(context, uv5rProfile);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Tick the box, then cancel anyway: a ticked box is not a confirmation.
    await _acknowledge(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });

  testWidgets('says when a radio\'s limits are unconfirmed', (tester) async {
    // The AR-152 programs as a BF-F8HP, so its band-limit fields are inferred
    // from a sibling rather than read off one. Saying so is the difference
    // between a considered choice and a surprise.
    await _show(tester, ar152Profile);
    expect(find.textContaining('not been confirmed'), findsOneWidget);
    expect(find.textContaining('backup'), findsOneWidget);
  });

  testWidgets('every unlockable radio currently says it is unconfirmed',
      (tester) async {
    // No profile carries verified: true yet, because nobody has read a
    // band-limit field off real hardware -- so every one of these dialogs
    // says so. When the bench Mini confirms its layout and that profile flips
    // to verified, this test fails and should be narrowed rather than
    // deleted: the warning must still appear for the radios still inferred.
    for (final profile in radioProfiles) {
      if (!profile.txUnlock.supported) continue;
      expect(profile.txUnlock.verified, isFalse, reason: profile.id);
    }

    await _show(tester, uv5rProfile);
    expect(find.textContaining('not been confirmed'), findsOneWidget);
  });
}
