// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/screens/about_screen.dart';

void main() {
  testWidgets('links the privacy policy, the disclaimer and the licences', (
    tester,
  ) async {
    // The Terms gate is shown once; this is where those links live after it.
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));

    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text(AppConstants.privacyUrl), findsOneWidget);
    expect(find.text('Disclaimer and terms'), findsOneWidget);
    expect(find.text(AppConstants.disclaimerUrl), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);
    expect(find.textContaining('Independent and unofficial'), findsOneWidget);
  });

  testWidgets('the licences entry opens the Flutter licence page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
    await tester.tap(find.text('Open-source licences'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
