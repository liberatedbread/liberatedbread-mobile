// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/screens/setup_instructions_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

const _full = SetupInstructionsDto(
  notes: 'Enable Bluetooth on the mug, then connect.',
  methods: [
    SetupMethodDto(
      methodType: 'ble_direct',
      description: 'Pair directly over BLE.',
      steps: [
        SetupStepDto(
          action: 'Hold the base button until the LED turns blue.',
          actor: 'user',
          expect: 'The LED blinks blue.',
        ),
        SetupStepDto(action: 'Connect and read state.', actor: 'client'),
      ],
      troubleshooting: [
        TroubleshootingDto(
          symptom: 'The mug will not connect.',
          causes: [
            'A phone is still holding the single allowed connection.',
            'The mug is asleep off the coaster.',
          ],
        ),
      ],
    ),
  ],
  factoryReset: FactoryResetDto(
    effect: 'Clears the claim; identity survives.',
    procedures: [
      FactoryResetProcedureDto(
        name: 'Factory reset',
        holdSeconds: 15,
        indicator: 'LED blue, then yellow, then red.',
        steps: [
          SetupStepDto(
            action: 'Hold through blue and yellow, release at red.',
            actor: 'user',
          ),
        ],
      ),
    ],
  ),
  rejoin: RejoinDto(
    inPlaceSupported: true,
    requiresFactoryReset: false,
    notes: 'Close the other client, or power-cycle on the coaster.',
  ),
);

Future<void> _pump(WidgetTester tester, SetupInstructionsDto instructions) {
  // The screen is a scrolling ListView; a tall surface lets every section
  // build so the assertions do not have to scroll each one into view.
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(MaterialApp(
    home: SetupInstructionsScreen(
      deviceName: 'Ember Mug',
      instructions: instructions,
    ),
  ));
}

void main() {
  testWidgets('renders every labelled section from the instructions',
      (tester) async {
    await _pump(tester, _full);

    // The matched product name and the app-bar title.
    expect(find.text('Ember Mug'), findsOneWidget);
    expect(find.text('Setup & troubleshooting'), findsOneWidget);

    // Rejoin note leads as "Try this first" — the real answer to "why won't it
    // connect" for a single-connection device.
    expect(find.text('Try this first'), findsOneWidget);
    expect(
      find.textContaining('Close the other client'),
      findsOneWidget,
    );

    // Troubleshooting, pairing steps, and the reset section each render with
    // their heading.
    expect(find.text('If it won’t connect'), findsOneWidget);
    expect(find.textContaining('will not connect'), findsOneWidget);
    expect(find.textContaining('single allowed connection'), findsOneWidget);
    expect(find.text('How to pair'), findsOneWidget);
    expect(find.textContaining('Hold the base button until the LED turns blue'),
        findsOneWidget);
    // Both the section heading and the single procedure are named "Factory
    // reset" for Ember, so it appears twice.
    expect(find.text('Factory reset'), findsWidgets);
    expect(find.textContaining('Hold through blue and yellow'), findsOneWidget);
    expect(
        find.textContaining('LED blue, then yellow, then red'), findsOneWidget);
  });

  testWidgets('omitted sections render no empty headings', (tester) async {
    // Only a rejoin note: none of the other section headings should appear.
    await _pump(
      tester,
      const SetupInstructionsDto(
        notes: null,
        methods: [],
        factoryReset: null,
        rejoin: RejoinDto(
          inPlaceSupported: true,
          requiresFactoryReset: false,
          notes: 'Just move it back onto the coaster.',
        ),
      ),
    );

    expect(find.text('Try this first'), findsOneWidget);
    expect(
        find.textContaining('move it back onto the coaster'), findsOneWidget);
    expect(find.text('If it won’t connect'), findsNothing);
    expect(find.text('How to pair'), findsNothing);
    expect(find.text('Factory reset'), findsNothing);
    expect(find.text('Overview'), findsNothing);
  });
}
