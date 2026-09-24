// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/safety_advisory_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

SafetyAdvisoryDto _advisory({
  required bool acknowledgeRequired,
  String severity = 'danger',
}) => SafetyAdvisoryDto(
  severity: severity,
  summary: 'Intense light can permanently burn skin.',
  detail: 'Patch-test and match the intensity to your skin tone.',
  acknowledgeRequired: acknowledgeRequired,
  advisoryUrl: 'https://example.test/safety',
  advisoryArchiveUrl:
      'https://web.archive.org/web/2/https://example.test/safety',
);

void main() {
  late SharedPreferences prefs;

  Future<void> pump(
    WidgetTester tester,
    SafetyAdvisoryDto advisory, {
    String ackKey = 'dev-1',
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: Scaffold(
            body: SafetyAdvisoryGate(
              advisory: advisory,
              ackKey: ackKey,
              child: const Text('CONTROLS'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  testWidgets(
    'no acknowledgement required: banner and controls show together',
    (tester) async {
      await pump(tester, _advisory(acknowledgeRequired: false));
      expect(find.text('Safety warning'), findsOneWidget);
      expect(find.textContaining('permanently burn'), findsOneWidget);
      expect(find.text('CONTROLS'), findsOneWidget);
      // No gate button when acknowledgement is not required.
      expect(find.textContaining('I understand'), findsNothing);
    },
  );

  testWidgets('acknowledge_required gates the controls until accepted', (
    tester,
  ) async {
    await pump(tester, _advisory(acknowledgeRequired: true));
    // Controls hidden; the banner and the consent button are shown.
    expect(find.text('CONTROLS'), findsNothing);
    expect(find.text('Safety warning'), findsOneWidget);
    final button = find.textContaining('I understand');
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();

    // Controls now show, and the acknowledgement was remembered.
    expect(find.text('CONTROLS'), findsOneWidget);
    expect(prefs.getString('${SafetyAdvisoryGate.prefsPrefix}dev-1'), 'danger');
  });

  testWidgets('a remembered acknowledgement shows controls immediately', (
    tester,
  ) async {
    await prefs.setString('${SafetyAdvisoryGate.prefsPrefix}dev-1', 'danger');
    await pump(tester, _advisory(acknowledgeRequired: true));
    expect(find.text('CONTROLS'), findsOneWidget);
    expect(find.textContaining('I understand'), findsNothing);
    // The banner is still present over the controls.
    expect(find.text('Safety warning'), findsOneWidget);
  });

  testWidgets('the banner offers both the live and archived safety links', (
    tester,
  ) async {
    // acknowledge_required expands the banner (detail + links) before consent,
    // which is where the links matter most.
    await pump(tester, _advisory(acknowledgeRequired: true));
    expect(
      find.widgetWithText(OutlinedButton, 'Safety instructions'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(OutlinedButton, 'Archived copy'),
      findsOneWidget,
    );
  });

  testWidgets('severity drives the banner label', (tester) async {
    await pump(
      tester,
      _advisory(acknowledgeRequired: false, severity: 'warning'),
    );
    expect(find.text('Use with care'), findsOneWidget);
  });
}
