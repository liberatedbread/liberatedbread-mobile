// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/providers/channel_plan_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/channel_plan_screen.dart';
import 'package:liberated_bread_mobile/screens/radio_device_screen.dart';
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
}) => {
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
    },
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

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPrefs),
      prefsSettingsStoreProvider.overrideWith(
        (ref) async => InMemorySettingsStore(),
      ),
      planExportServiceProvider.overrideWithValue(exporter),
      fileShareProvider.overrideWithValue((file) async => shared.add(file)),
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
  return _Harness(exporter, shared, container);
}

void main() {
  group('channelRangeProblem', () {
    // Broadcast FM is in every profile's rxRanges but is a separate
    // receiver on these radios: a memory channel there is one the radio
    // cannot use, receive-only or not.
    for (final profile in radioProfiles) {
      test('${profile.displayName} refuses a broadcast-FM channel', () {
        expect(
          channelRangeProblem(
            profile,
            rxFreqHz: 101100000,
            txFreqHz: 101100000,
            rxOnly: false,
          ),
          contains('Receive 101.100 MHz'),
        );
        expect(
          channelRangeProblem(
            profile,
            rxFreqHz: 101100000,
            txFreqHz: 101100000,
            rxOnly: true,
          ),
          isNotNull,
        );
        expect(
          channelRangeProblem(
            profile,
            rxFreqHz: 146520000,
            txFreqHz: 101100000,
            rxOnly: false,
          ),
          contains('Transmit 101.100 MHz'),
        );
      });

      test('${profile.displayName} still takes 2 m and 70 cm channels', () {
        for (final hz in [146520000, 446000000]) {
          expect(
            channelRangeProblem(
              profile,
              rxFreqHz: hz,
              txFreqHz: hz,
              rxOnly: false,
            ),
            isNull,
          );
        }
      });
    }

    test('memory ranges are receive ranges with broadcast FM left out', () {
      for (final profile in radioProfiles) {
        final ranges = memoryChannelRanges(profile);
        expect(ranges, isNotEmpty);
        expect(profile.rxRanges, containsAll(ranges));
        expect(rangesContain(ranges, 101100000), isFalse);
        // Exactly one range (the FM receiver) is left out: a usable band
        // starting at or below the 108 MHz cut-off would otherwise vanish
        // from the editor and the write gate without a failing test.
        expect(ranges, hasLength(profile.rxRanges.length - 1));
      }
    });
  });

  testWidgets('lists channels with slot numbers and a capacity readout', (
    tester,
  ) async {
    await _pump(tester, prefs: _seed());
    expect(find.text('Local repeaters'), findsOneWidget);
    expect(find.text('CH0'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('3 of 999 channels'), findsOneWidget);
  });

  testWidgets('shows each channel\'s frequency, offset and mode', (
    tester,
  ) async {
    await _pump(tester, prefs: _seed(channels: 1));
    expect(find.textContaining('146.940 MHz'), findsOneWidget);
    expect(find.textContaining('−0.600'), findsOneWidget);
    expect(find.textContaining('FM'), findsOneWidget);
  });

  testWidgets('an empty plan says how to fill it', (tester) async {
    await _pump(tester, prefs: _seed(channels: 0));
    expect(find.textContaining('No channels yet'), findsOneWidget);
  });

  testWidgets('a plan that no longer exists says so rather than crashing', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('This plan no longer exists.'), findsOneWidget);
  });

  testWidgets('banners a plan built with the transmit range widened', (
    tester,
  ) async {
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

    testWidgets(
      'a long-press drag cannot move a row out from under its tick',
      (tester) async {
        // Regression: the SDK's default drag handles made a long-press
        // anywhere on a row start a reorder, select mode or not. Ticks are
        // slot indices, so dragging CH2 above the ticked CH1 left the tick
        // on slot 1 — now CH2 — and "Delete selected" removed CH2.
        final harness = await _pump(tester, prefs: _seed());
        await tester.tap(find.byIcon(Icons.checklist));
        await tester.pumpAndSettle();
        await tester.tap(find.text('CH1'));
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('CH2')),
        );
        await tester.pump(kLongPressTimeout + kPressTimeout);
        await gesture.moveTo(tester.getCenter(find.text('CH0')));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        List<String> names() => [
          for (final channel
              in harness.container.read(channelPlansProvider).single.channels)
            channel.name,
        ];
        expect(names(), ['CH0', 'CH1', 'CH2']);

        await tester.tap(find.byIcon(Icons.delete_outline));
        await tester.pumpAndSettle();
        expect(names(), ['CH0', 'CH2']);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'a desktop row has one drag handle, not the SDK\'s second',
      (tester) async {
        await _pump(tester, prefs: _seed());
        expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('outside it, the trailing handle still reorders', (
      tester,
    ) async {
      final harness = await _pump(tester, prefs: _seed());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.drag_handle).at(2)),
      );
      await tester.pump();
      final to = tester.getCenter(find.text('CH1'));
      final from = tester.getCenter(find.byIcon(Icons.drag_handle).at(2));
      // In steps, so the drag clears the touch slop before it travels.
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(
          Offset(from.dx, from.dy + (to.dy - from.dy) * i / 10),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        [
          for (final channel
              in harness.container.read(channelPlansProvider).single.channels)
            channel.name,
        ],
        ['CH0', 'CH2', 'CH1'],
      );
    });

    testWidgets('its close button is named for a screen reader', (
      tester,
    ) async {
      await _pump(tester, prefs: _seed());
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel selection'), findsOneWidget);
    });

    testWidgets('can be left without deleting anything', (tester) async {
      final harness = await _pump(tester, prefs: _seed());
      await tester.tap(find.byIcon(Icons.checklist));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(
        harness.container.read(channelPlansProvider).single.channels,
        hasLength(3),
      );
      expect(find.text('Local repeaters'), findsOneWidget);
    });

    testWidgets('is not offered for an empty plan', (tester) async {
      await _pump(tester, prefs: _seed(channels: 0));
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.checklist),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('adding a channel', () {
    /// Open the sheet and type a simplex channel in; the caller saves.
    Future<void> typeIn(WidgetTester tester, String name, String mhz) async {
      await tester.tap(find.byTooltip('Add channel'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), name);
      await tester.enterText(
        find.widgetWithText(TextField, 'Receive (MHz)'),
        mhz,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Transmit (MHz)'),
        mhz,
      );
    }

    testWidgets('is offered for an empty plan', (tester) async {
      // The one action that must work with nothing in the plan: it is the
      // only way to fill one by hand.
      await _pump(tester, prefs: _seed(channels: 0));
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('Tap + to add one'), findsOneWidget);
    });

    testWidgets('opens a blank sheet, not one pre-filled with a frequency', (
      tester,
    ) async {
      await _pump(tester, prefs: _seed(channels: 0));
      await tester.tap(find.byTooltip('Add channel'));
      await tester.pumpAndSettle();

      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.controller?.text, isEmpty);
      }
      expect(find.text('0.000'), findsNothing);
    });

    testWidgets('appends a typed-in channel to an empty plan', (tester) async {
      final harness = await _pump(tester, prefs: _seed(channels: 0));
      await typeIn(tester, 'Calling', '146.520');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final channel = harness.container
          .read(channelPlansProvider)
          .single
          .channels
          .single;
      expect(channel.name, 'Calling');
      expect(channel.rxFreqHz, 146520000);
      expect(channel.txFreqHz, 146520000);
      expect(find.text('Calling'), findsOneWidget);
      expect(find.textContaining('No channels yet'), findsNothing);
    });

    testWidgets('refuses to save without a frequency', (tester) async {
      final harness = await _pump(tester, prefs: _seed(channels: 0));
      await tester.tap(find.byTooltip('Add channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('should look like'), findsOneWidget);
      expect(
        harness.container.read(channelPlansProvider).single.channels,
        isEmpty,
      );
    });

    testWidgets('cancelling adds nothing', (tester) async {
      final harness = await _pump(tester, prefs: _seed(channels: 0));
      await typeIn(tester, 'Calling', '146.520');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(
        harness.container.read(channelPlansProvider).single.channels,
        isEmpty,
      );
      expect(find.textContaining('No channels yet'), findsOneWidget);
    });

    testWidgets('says so when the plan is full', (tester) async {
      // A UV-5R holds 128; the screen says so the moment + is tapped, before
      // anyone types a channel in that the provider would refuse.
      final harness = await _pump(
        tester,
        prefs: _seed(channels: 128, profileId: 'uv5r'),
      );
      await tester.tap(find.byTooltip('Add channel'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
      expect(find.textContaining('Did not fit'), findsOneWidget);
      expect(find.textContaining('holds 128'), findsOneWidget);
      expect(
        harness.container.read(channelPlansProvider).single.channels,
        hasLength(128),
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
        'Renamed',
      );
    });

    testWidgets('refuses a frequency that is not one', (tester) async {
      await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '146.940'),
        'about 146',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('should look like'), findsOneWidget);
    });

    // Only "> 0" used to be checked: a dropped digit was saved and written
    // as a channel the radio cannot tune, and an extra one failed every
    // Write after a full read and backup.
    testWidgets('refuses a receive frequency the radio cannot tune', (
      tester,
    ) async {
      final harness = await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '146.940'),
        '46.940',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Receive 46.940 MHz is outside what a'),
        findsOneWidget,
      );
      final channel = harness.container
          .read(channelPlansProvider)
          .single
          .channels
          .single;
      expect(channel.rxFreqHz, 146940000);
    });

    testWidgets('refuses a transmit frequency the radio cannot tune', (
      tester,
    ) async {
      final harness = await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, '146.340'),
        '1462.550',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Transmit 1462.550 MHz'), findsOneWidget);
      final channel = harness.container
          .read(channelPlansProvider)
          .single
          .channels
          .single;
      expect(channel.txFreqHz, 146340000);
    });

    testWidgets('a receive-only channel drops its transmit tone', (
      tester,
    ) async {
      final harness = await _pump(tester, prefs: _seed(channels: 1));
      await tester.tap(find.text('CH0'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Receive only'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final channel = harness.container
          .read(channelPlansProvider)
          .single
          .channels
          .single;
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
              find.widgetWithIcon(IconButton, Icons.ios_share),
            )
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

  group('programming a radio', () {
    const savedRadios =
        '[{"transport":"ble","id":"AA:BB","name":"Base radio",'
        '"lastSeen":"2026-09-01T12:00:00.000","radioProfileId":"uv-5r-mini"},'
        '{"transport":"usb","id":"/dev/ttyUSB0","name":"Cable radio",'
        '"lastSeen":"2026-09-01T12:00:00.000","radioProfileId":"uv5r"}]';

    testWidgets(
      'offers the saved radios that can take the plan, and opens one with it',
      (tester) async {
        await _pump(
          tester,
          prefs: {..._seed(), 'saved_radios_v1': savedRadios},
        );
        await tester.tap(find.byTooltip('Program radio'));
        await tester.pumpAndSettle();

        expect(find.text('Base radio'), findsOneWidget);
        expect(
          find.text('Cable radio'),
          findsNothing,
          reason: 'a UV-5R Mini plan goes over Bluetooth, not a cable',
        );

        await tester.tap(find.text('Base radio'));
        await tester.pumpAndSettle();
        final screen = tester.widget<RadioDeviceScreen>(
          find.byType(RadioDeviceScreen),
        );
        expect(screen.target.id, 'AA:BB');
        expect(screen.planId, 'p1');
        expect(screen.initialProfile?.id, 'uv-5r-mini');
        expect(find.text('Write "Local repeaters"'), findsOneWidget);
      },
    );

    testWidgets('with none saved, says where radios are found', (tester) async {
      await _pump(tester, prefs: _seed());
      await tester.tap(find.byTooltip('Program radio'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No Baofeng UV-5R Mini saved yet'),
        findsOneWidget,
      );
      expect(find.textContaining('Nearby'), findsOneWidget);
      expect(find.textContaining('USB tab'), findsOneWidget);
    });
  });
}
