// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/screens/setup_instructions_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

const _full = SetupInstructionsDto(
  notes: 'Enable Bluetooth on the mug, then connect.',
  methods: [
    SetupMethodDto(
      methodType: 'ble_direct',
      description: 'Pair directly over BLE.',
      stages: [],
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
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: SetupInstructionsScreen(
          deviceName: 'Ember Mug',
          instructions: instructions,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders every labelled section from the instructions', (
    tester,
  ) async {
    await _pump(tester, _full);

    // The matched product name and the app-bar title.
    expect(find.text('Ember Mug'), findsOneWidget);
    expect(find.text('Setup & troubleshooting'), findsOneWidget);

    // Rejoin note leads as "Try this first" — the real answer to "why won't it
    // connect" for a single-connection device.
    expect(find.text('Try this first'), findsOneWidget);
    expect(find.textContaining('Close the other client'), findsOneWidget);

    // Troubleshooting, pairing steps, and the reset section each render with
    // their heading.
    expect(find.text('If it won’t connect'), findsOneWidget);
    expect(find.textContaining('will not connect'), findsOneWidget);
    expect(find.textContaining('single allowed connection'), findsOneWidget);
    expect(find.text('How to pair'), findsOneWidget);
    expect(
      find.textContaining('Hold the base button until the LED turns blue'),
      findsOneWidget,
    );
    // Both the section heading and the single procedure are named "Factory
    // reset" for Ember, so it appears twice.
    expect(find.text('Factory reset'), findsWidgets);
    expect(find.textContaining('Hold through blue and yellow'), findsOneWidget);
    expect(
      find.textContaining('LED blue, then yellow, then red'),
      findsOneWidget,
    );
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
      find.textContaining('move it back onto the coaster'),
      findsOneWidget,
    );
    expect(find.text('If it won’t connect'), findsNothing);
    expect(find.text('How to pair'), findsNothing);
    expect(find.text('Factory reset'), findsNothing);
    expect(find.text('Overview'), findsNothing);
  });

  testWidgets('a staged route renders every phase with its own steps', (
    tester,
  ) async {
    // The hue-bridge shape after the catalogue's setup restructure: one named
    // primary route whose steps live entirely on its two stages. Losing the
    // stages loses the whole procedure — the exact break this guards.
    await _pump(
      tester,
      const SetupInstructionsDto(
        notes: null,
        methods: [
          SetupMethodDto(
            methodType: 'wired',
            name: 'Ethernet, then the link button',
            role: 'primary',
            description: 'Two things have to happen and neither is a choice.',
            steps: [],
            stages: [
              SetupStageDto(
                name: 'Get the bridge onto the LAN',
                methodType: 'wired',
                description: null,
                steps: [
                  SetupStepDto(
                    action: 'Plug the bridge into the router.',
                    actor: 'user',
                  ),
                ],
                troubleshooting: [],
              ),
              SetupStageDto(
                name: 'Authorize this client at the link button',
                methodType: 'button_pairing',
                description: null,
                steps: [
                  SetupStepDto(action: 'Press the link button.', actor: 'user'),
                  SetupStepDto(
                    action: 'Create a user.',
                    actor: 'client',
                    expect: 'A username in the reply.',
                  ),
                ],
                troubleshooting: [],
              ),
            ],
            troubleshooting: [],
          ),
        ],
        factoryReset: null,
        rejoin: null,
      ),
    );

    // The route's own name is the section title — not a generic heading.
    expect(find.text('Ethernet, then the link button'), findsOneWidget);
    expect(find.text('How to pair'), findsNothing);
    // Both phases render, in order, with their steps.
    expect(
      find.textContaining('1 of 2 — Get the bridge onto the LAN'),
      findsOneWidget,
    );
    expect(
      find.textContaining('2 of 2 — Authorize this client at the link button'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Plug the bridge into the router'),
      findsOneWidget,
    );
    expect(find.textContaining('Press the link button'), findsOneWidget);
    expect(find.textContaining('A username in the reply'), findsOneWidget);
    // Primary needs no qualifier label.
    expect(find.text('Also works'), findsNothing);
  });

  testWidgets('non-primary roles are labelled and named routes are choosable', (
    tester,
  ) async {
    await _pump(
      tester,
      const SetupInstructionsDto(
        notes: null,
        methods: [
          SetupMethodDto(
            methodType: 'hub_pairing',
            name: 'HomeKit pairing',
            role: 'primary',
            description: 'The account-free route.',
            steps: [],
            stages: [],
            troubleshooting: [],
          ),
          SetupMethodDto(
            methodType: 'softap_http',
            name: 'Gen 3 setup AP',
            role: 'variant',
            description: 'Gen 3 units only.',
            steps: [],
            stages: [],
            troubleshooting: [],
          ),
        ],
        factoryReset: null,
        rejoin: null,
      ),
    );

    expect(find.text('HomeKit pairing'), findsOneWidget);
    expect(find.text('Gen 3 setup AP'), findsOneWidget);
    expect(find.text('Depends on the hardware'), findsOneWidget);
  });
}
