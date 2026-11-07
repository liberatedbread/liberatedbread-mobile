// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_pairing_guide_provider.dart';
import 'package:liberated_bread_mobile/screens/ble_pairing_guide_screen.dart';
import 'package:liberated_bread_mobile/screens/setup_instructions_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

BlePairingGuideEntry _entry(String name, String maker, String step) =>
    BlePairingGuideEntry(
      deviceName: name,
      manufacturer: maker,
      category: 'light',
      pictogram: null,
      instructions: SetupInstructionsDto(
        methods: [
          SetupMethodDto(
            methodType: 'ble_direct',
            stages: const [],
            steps: [SetupStepDto(action: step, actor: 'user')],
            troubleshooting: const [],
          ),
        ],
      ),
    );

final _entries = [
  _entry('Ember Mug', 'Ember', 'Tap the base twice.'),
  _entry('Govee Strip Light', 'Govee', 'Power it on.'),
  _entry('Govee Bulb', 'Govee', 'Flick it three times.'),
];

Future<void> _pump(
  WidgetTester tester,
  Future<List<BlePairingGuideEntry>> Function() guide,
) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [blePairingGuideProvider.overrideWith((ref) => guide())],
      child: const MaterialApp(home: BlePairingGuideScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the general steps and every device', (tester) async {
    await _pump(tester, () async => _entries);

    expect(find.text('Pairing a new device'), findsOneWidget);
    expect(
      find.textContaining('Put the device in pairing mode'),
      findsOneWidget,
    );
    expect(find.textContaining('Go back to Nearby and scan'), findsOneWidget);
    for (final e in _entries) {
      expect(find.text(e.deviceName), findsOneWidget);
    }
    // The maker under each name.
    expect(find.text('Govee'), findsNWidgets(2));
  });

  testWidgets('search narrows by name and maker, every term', (tester) async {
    await _pump(tester, () async => _entries);

    await tester.enterText(find.byType(TextField), 'govee');
    await tester.pump();
    expect(find.text('Ember Mug'), findsNothing);
    expect(find.text('Govee Bulb'), findsOneWidget);
    expect(find.text('Govee Strip Light'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'GOVEE strip');
    await tester.pump();
    expect(find.text('Govee Bulb'), findsNothing);
    expect(find.text('Govee Strip Light'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'toaster');
    await tester.pump();
    expect(find.textContaining('Nothing matches "toaster"'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Ember Mug'), findsOneWidget);
  });

  testWidgets('a row opens that device’s instructions, steps first', (
    tester,
  ) async {
    await _pump(tester, () async => _entries);

    await tester.tap(find.text('Ember Mug'));
    await tester.pumpAndSettle();

    final screen = tester.widget<SetupInstructionsScreen>(
      find.byType(SetupInstructionsScreen),
    );
    expect(screen.deviceName, 'Ember Mug');
    expect(screen.afterFailedConnect, isFalse);
    expect(find.text('Tap the base twice.'), findsOneWidget);
  });

  testWidgets('an empty catalogue says so instead of a bare heading', (
    tester,
  ) async {
    await _pump(tester, () async => const []);

    expect(
      find.text('No pairing instructions are in the catalogue yet.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Which device?'), findsNothing);
  });

  testWidgets('a catalogue that will not load says so', (tester) async {
    await _pump(tester, () async => throw StateError('no catalogue'));

    expect(find.text('Could not read the device catalogue.'), findsOneWidget);
  });
}
