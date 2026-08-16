// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/screens/security_warning_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart'
    show MatchConfidence, SecurityAdvisoryDto;

IoTDevice _device() => IoTDevice(
      id: 'AA:BB:CC:DD:EE:01',
      name: 'KARR_ALARM',
      rssi: -55,
      isConnectable: false,
      discoveredAt: DateTime.utc(2026),
      serviceUuids: const [],
      companyIds: const [],
    );

ScanGuess _guess(SecurityAdvisoryDto advisory,
        {MatchConfidence confidence = MatchConfidence.possible}) =>
    ScanGuess(
      deviceName: 'KARR / SWDS Vehicle Alarm',
      manufacturer: 'Acrisure',
      confidence: confidence,
      otherMatches: 0,
      manufacturerAgreed: true,
      category: null,
      advisory: advisory,
    );

Future<void> _pump(WidgetTester tester, SecurityAdvisoryDto advisory,
        {MatchConfidence confidence = MatchConfidence.possible}) =>
    tester.pumpWidget(MaterialApp(
      home: SecurityWarningScreen(
        device: _device(),
        advisory: advisory,
        guess: _guess(advisory, confidence: confidence),
      ),
    ));

void main() {
  testWidgets('a vulnerable device shows the risk and the fix', (tester) async {
    await _pump(
      tester,
      const SecurityAdvisoryDto(
        severity: 'vulnerable',
        summary: 'A shared key unlocks and immobilizes the car.',
        detail: 'The longer explanation of the flaw.',
        advisoryUrl: 'https://example.test/advisory',
        mitigationSummary: 'Update the firmware in the KARR app.',
        mitigationUrl: 'https://example.test/patch',
      ),
    );

    expect(find.text('Known vulnerability'), findsOneWidget);
    expect(find.textContaining('shared key'), findsOneWidget);
    expect(find.textContaining('longer explanation'), findsOneWidget);
    // The fix is the most useful thing here, and it is present.
    expect(find.text('How to fix it'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open the fix'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Read the advisory'),
        findsOneWidget);
  });

  testWidgets('a malicious device says do not trust it and shows no fix card',
      (tester) async {
    await _pump(
      tester,
      const SecurityAdvisoryDto(
        severity: 'malicious',
        summary: 'Skimmer module signature.',
        advisoryUrl: 'https://example.test/skimmer',
      ),
    );

    expect(find.text('Do not trust this device'), findsOneWidget);
    // No mitigation, and malicious devices are not "awaiting a fix".
    expect(find.text('How to fix it'), findsNothing);
    expect(find.text('No fix has been published yet.'), findsNothing);
  });

  testWidgets('a reported issue with no fix says so', (tester) async {
    await _pump(
      tester,
      const SecurityAdvisoryDto(
        severity: 'reported',
        summary: 'Replayable — harder to exploit.',
        advisoryUrl: 'https://example.test/reported',
      ),
    );

    expect(find.text('Reported issue'), findsOneWidget);
    expect(find.text('No fix has been published yet.'), findsOneWidget);
  });

  testWidgets('a possible match hedges the wording', (tester) async {
    await _pump(
      tester,
      const SecurityAdvisoryDto(
          severity: 'malicious', summary: 'Skimmer module signature.'),
      confidence: MatchConfidence.possible,
    );

    expect(find.textContaining('This might be'), findsOneWidget);
  });
}
