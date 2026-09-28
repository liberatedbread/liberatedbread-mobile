// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The channel plan's power display and editor. A UV-32 (and a BF-F8HP) has a
// Medium level the plan could not name: it showed as "low power" and the
// editor offered only High and Low.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/providers/channel_plan_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/channel_plan_screen.dart';
import 'package:liberated_bread_mobile/services/plan_export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/in_memory_settings_store.dart';

class _UnusedExportService implements PlanExportService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object> _seed(String profileId, List<String> powers) => {
  'radio_channel_plans_v1': jsonEncode([
    {
      'id': 'p1',
      'name': 'Power',
      'radioProfileId': profileId,
      'channels': [
        for (var i = 0; i < powers.length; i++)
          {
            'name': 'CH$i',
            'rx': 146520000 + i * 20000,
            'tx': 146520000 + i * 20000,
            'power': powers[i],
          },
      ],
      'createdAt': '2026-08-01T00:00:00.000Z',
      'modifiedAt': '2026-08-02T00:00:00.000Z',
    },
  ]),
};

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Map<String, Object> prefs,
) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPrefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPrefs),
      prefsSettingsStoreProvider.overrideWith(
        (ref) async => InMemorySettingsStore(),
      ),
      planExportServiceProvider.overrideWithValue(_UnusedExportService()),
      fileShareProvider.overrideWithValue((file) async {}),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ChannelPlanScreen(planId: 'p1')),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _segment(String label) => find.descendant(
  of: find.byType(SegmentedButton<PowerLevel>),
  matching: find.text(label),
);

void main() {
  testWidgets('a medium channel says medium, not low', (tester) async {
    await _pump(tester, _seed('uv-32', ['medium', 'low', 'high']));
    expect(find.textContaining('medium power'), findsOneWidget);
    expect(find.textContaining('low power'), findsOneWidget);
  });

  testWidgets('a UV-32 plan offers and saves Medium', (tester) async {
    final container = await _pump(tester, _seed('uv-32', ['low']));
    await tester.tap(find.text('CH0'));
    await tester.pumpAndSettle();

    expect(_segment('High'), findsOneWidget);
    expect(_segment('Medium'), findsOneWidget);
    expect(_segment('Low'), findsOneWidget);

    await tester.tap(_segment('Medium'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      container.read(channelPlansProvider).single.channels.single.power,
      PowerLevel.medium,
    );
  });

  testWidgets('a UV-82HP plan offers Medium', (tester) async {
    // The HP's Med had no name while it was programmed as a UV-5R.
    await _pump(tester, _seed('uv-82hp', ['low']));
    await tester.tap(find.text('CH0'));
    await tester.pumpAndSettle();
    expect(_segment('High'), findsOneWidget);
    expect(_segment('Medium'), findsOneWidget);
    expect(_segment('Low'), findsOneWidget);
  });

  testWidgets('a Mini plan offers no Medium', (tester) async {
    await _pump(tester, _seed('uv-5r-mini', ['high']));
    await tester.tap(find.text('CH0'));
    await tester.pumpAndSettle();

    expect(_segment('High'), findsOneWidget);
    expect(_segment('Low'), findsOneWidget);
    expect(_segment('Medium'), findsNothing);
  });

  testWidgets('a medium channel on a Mini plan still shows what it holds', (
    tester,
  ) async {
    // A UV-32 plan retargeted at a Mini: hiding the selected level would
    // leave the editor showing no power at all.
    await _pump(tester, _seed('uv-5r-mini', ['medium']));
    await tester.tap(find.text('CH0'));
    await tester.pumpAndSettle();
    expect(_segment('Medium'), findsOneWidget);
  });
}
