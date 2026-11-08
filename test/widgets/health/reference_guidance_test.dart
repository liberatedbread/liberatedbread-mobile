// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/health_reference.dart';
import 'package:liberated_bread_mobile/models/health_measurement_plan.dart';
import 'package:liberated_bread_mobile/widgets/health/reference_guidance.dart';

void main() {
  testWidgets('blood-pressure source sheet links both public references', (
    tester,
  ) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HealthReferenceGuidance(
            kind: HealthMeasurementKind.bloodPressure,
            nih: bloodPressureNihReference(135, 85),
            manufacturer: bloodPressureBeurerReference(135, 85),
            launcher: (uri) async {
              opened.add(uri);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ranges & sources'));
    await tester.pumpAndSettle();

    expect(find.text('Blood-pressure references'), findsOneWidget);
    expect(find.text('High blood pressure · stage 1'), findsWidgets);
    expect(find.text('High normal'), findsWidgets);
    expect(find.text('>180 OR >120 mmHg'), findsOneWidget);
    expect(find.text('≥180 OR ≥110 mmHg'), findsOneWidget);
    expect(find.textContaining('Do not start, stop or change'), findsOneWidget);

    await tester.tap(find.text('Open public source').first);
    await tester.pump();
    await tester.ensureVisible(find.text('Open public source').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open public source').last);
    await tester.pump();
    expect(opened.map((uri) => uri.toString()), [
      nihBloodPressureUrl,
      beurerBm92ManualUrl,
    ]);
  });

  testWidgets('F7 does not invent a manufacturer reference scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HealthReferenceGuidance(
            kind: HealthMeasurementKind.pulseOximeter,
            nih: HealthReferenceRow(
              'Common adult range',
              '95–100% SpO₂',
              HealthReferenceTone.normal,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ranges & sources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No verified companion-app'), findsOneWidget);
    expect(find.text('Open public source'), findsOneWidget);
  });
}
