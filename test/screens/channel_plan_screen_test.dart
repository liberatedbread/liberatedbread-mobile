// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/providers/channel_plan_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/channel_plan_screen.dart';
import 'package:liberated_bread_mobile/services/plan_export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/in_memory_settings_store.dart';

/// An exporter that records rather than writing, so no widget test does real
/// file I/O -- which never completes inside `testWidgets`' fake-async zone.
class _RecordingExportService implements PlanExportService {
  final List<ChannelPlan> exported = [];
  Object? error;

  @override
  Future<ExportedFile> exportChirpCsv(ChannelPlan plan) async {
    final failure = error;
    if (failure != null) throw failure;
    exported.add(plan);
    return ExportedFile(
      file: File('/tmp/${PlanExportService.fileNameFor(plan)}.csv'),
      displayName: '${PlanExportService.fileNameFor(plan)}.csv',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object> _seed({
  int channels = 3,
  bool unlock = false,
  String profileId = 'uv-5r-mini',
}) =>
    {
      'radio_channel_plans_v1': jsonEncode([
        {
          'id': 'p1',
          'name': 'Local repeaters',
          'radioProfileId': profileId,
          'channels': [
            for (var i = 0; i < channels; i++)
              {
                'name': 'CH$i',
                'rx': 146940000 + i * 25000,
                'tx': 146340000 + i * 25000,
              },
          ],
          if (unlock) 'builtWithTxUnlock': true,
          'createdAt': '2026-08-01T00:00:00.000Z',
          'modifiedAt': '2026-08-02T00:00:00.000Z',
        }
      ]),
    };

class _Harness {
  final _RecordingExportService exporter;
  final List<ExportedFile> shared;
  final ProviderContainer container;

  _Harness(this.exporter, this.shared, this.container);
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  Object? exportError,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPrefs = await SharedPreferences.getInstance();
  final exporter = _RecordingExportService()..error = exportError;
  final shared = <ExportedFile>[];

  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(sharedPrefs),
    prefsSettingsStoreProvider
        .overrideWith((ref) async => InMemorySettingsStore()),
    planExportServiceProvider.overrideWithValue(exporter),
    fileShareProvider.overrideWithValue((file) async => shared.add(file)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ChannelPlanScreen(planId: 'p1')),
  ));
  await tester.pumpAndSettle();
  return _Harness(exporter, shared, container);
}

void main() {
  testWidgets('lists channels with slot numbers and a capacity readout',
      (tester) async {
    await _pump(tester, prefs: _seed());
    expect(find.text('Local repeaters'), findsOneWidget);
    expect(find.text('CH0'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('3 of 999 channels'), findsOneWidget);
  });

  testWidgets('shows each channel\'s frequency, offset and mode',
      (tester) async {
    await _pump(tester, prefs: _seed(channels: 1));
    expect(find.textContaining('146.940 MHz'), findsOneWidget);
    expect(find.textContaining('−0.600'), findsOneWidget);
    expect(find.textContaining('FM'), findsOneWidget);
  });

  testWidgets('an empty plan says how to fill it', (tester) async {
    await _pump(tester, prefs: _seed(channels: 0));
    expect(find.textContaining('No channels yet'), findsOneWidget);
  });

  testWidgets('a plan that no longer exists says so rather than crashing',
      (tester) async {
    await _pump(tester);
    expect(find.text('This plan no longer exists.'), findsOneWidget);
  });

  testWidgets('banners a plan built with the transmit range widened',
      (tester) async {
    await _pump(tester, prefs: _seed(unlock: true));
    expect(find.textContaining('transmit range widened'), findsOneWidget);
    expect(find.textContaining('your own licence'), findsOneWidget);
  });

  testWidgets('an ordinary plan carries no banner', (tester) async {
    await _pump(tester, prefs: _seed());
    expect(find.textContaining('transmit range widened'), findsNothing);
  });

  group('multi-select', () {
    testWidgets('deletes the ticked slots', (tester) async {
      final harness = await _pump(tester, prefs: _seed());

      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      final plan = harness.container.read(channelPlansProvider).single;
      expect(plan.channels, hasLength(2));
      expect(plan.channels.first.name, 'CH1');
      // ...and the mode closes itself once the work is done.
      expect(find.text('Local repeaters'), findsOneWidget);
    });

    testWidgets('can be left without deleting anything', (tester) async {
      final harness = await _pump(tester, prefs: _seed());
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(harness.container.read(channelPlansProvider).single.channels,
          hasLength(3));
      expect(find.text('Local repeaters'), findsOneWidget);
    });

    testWidgets('is not offered for an empty plan', (tester) async {
      await _pump(tester, prefs: _seed(channels: 0));
      expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.checklist))
            .onPressed,
        isNull,
      );
    });
  });

  group('editing a channel', () {
    testWidgets('opens a sheet seeded from the channel', (tester) async {
      await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'CH0'), findsOneWidget);
      expect(find.widgetWithText(TextField, '146.940'), findsOneWidget);
      expect(find.textContaining('shows 12 characters'), findsOneWidget);
    });

    testWidgets('saves an edit back to the plan', (tester) async {
      final harness = await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'CH0'), 'Renamed');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
          harness.container
              .read(channelPlansProvider)
              .single
              .channels
              .single
              .name,
          'Renamed');
    });

    testWidgets('refuses a frequency that is not one', (tester) async {
      await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, '146.940'), 'about 146');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('should look like'), findsOneWidget);
    });

    testWidgets('a receive-only channel drops its transmit tone',
        (tester) async {
      final harness = await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Receive only'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final channel =
          harness.container.read(channelPlansProvider).single.channels.single;
      expect(channel.rxOnly, isTrue);
      expect(channel.txFreqHz, channel.rxFreqHz);
      expect(channel.txTone.isNone, isTrue);
    });
  });

  group('export', () {
    testWidgets('hands the plan to the exporter', (tester) async {
      final harness = await _pump(tester, prefs: _seed());
      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.pumpAndSettle();

      expect(harness.exporter.exported, hasLength(1));
      expect(harness.exporter.exported.single.name, 'Local repeaters');
    });

    testWidgets('is not offered for an empty plan', (tester) async {
      await _pump(tester, prefs: _seed(channels: 0));
      expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.ios_share))
            .onPressed,
        isNull,
      );
    });

    testWidgets('says so when it fails', (tester) async {
      await _pump(tester, prefs: _seed(), exportError: StateError('disk full'));
      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not export'), findsOneWidget);
    });
  });
}
