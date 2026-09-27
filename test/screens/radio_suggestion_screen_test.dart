// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/providers/location_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_bundled_data_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_source_settings_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_suggestion_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_suggestion_screen.dart';
import 'package:liberated_bread_mobile/services/channel_plan_store.dart';
import 'package:liberated_bread_mobile/services/channel_suggestion_service.dart';
import 'package:liberated_bread_mobile/services/radio_bundled_data.dart';
import 'package:liberated_bread_mobile/services/radio_source_cache.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_location_service.dart';
import '../fakes/fake_repeater_source.dart';
import '../fakes/in_memory_settings_store.dart';

const _hartford = GeoPoint(41.7658, -72.6734);

RepeaterListing _repeater(String name, int rxHz, int txHz) => RepeaterListing(
  channel: RadioChannel(name: name, rxFreqHz: rxHz, txFreqHz: txHz),
  category: SuggestionCategory.repeater,
  location: _hartford,
  callsign: name,
);

/// An empty plan for [profile], there before the screen opens.
ChannelPlan _plan(String id, String name, RadioProfile profile) => ChannelPlan(
  id: id,
  name: name,
  radioProfileId: profile.id,
  channels: const [],
  createdAt: DateTime(2026, 9, 1),
  modifiedAt: DateTime(2026, 9, 1),
);

Map<String, Object> _seedPlans(List<ChannelPlan> plans) => {
  'radio_channel_plans_v1': jsonEncode([for (final p in plans) p.toJson()]),
};

/// Bundled state extents without touching the asset bundle.
///
/// `testWidgets` runs its body inside a fake-async zone, and real I/O started
/// there never completes -- the test hangs rather than failing. So the widget
/// tests get their geography from here and their listings from a fake source,
/// leaving disk and network to the engine's own suite.
class _FakeBundledData extends RadioBundledData {
  @override
  Future<List<StateBounds>> stateBounds() async => const [
    StateBounds(
      code: 'CT',
      fips: '09',
      name: 'Connecticut',
      boxes: [(minLat: 40.98, minLon: -73.73, maxLat: 42.05, maxLon: -71.79)],
    ),
  ];
}

/// A cache with nowhere to write, so every read misses and every write is a
/// no-op. [RadioSourceCache] already degrades that way by design.
RadioSourceCache _noCache() => RadioSourceCache(
  cacheDirResolver: () async => throw StateError('no cache in widget tests'),
);

void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<SharedPreferences> _pump(
  WidgetTester tester, {
  required FakeLocationService location,
  List<RepeaterSource> sources = const [],
  RadioProfile profile = uv5rProfile,
  Map<String, Object> prefs = const {},
  InMemorySettingsStore? settings,
}) async {
  _useTallWindow(tester);
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPrefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPrefs),
        prefsSettingsStoreProvider.overrideWith(
          (ref) async => settings ?? InMemorySettingsStore(),
        ),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        locationServiceProvider.overrideWithValue(location),
        radioBundledDataProvider.overrideWithValue(_FakeBundledData()),
        // The screen builds its enabled-source set by walking this list, so the
        // fakes have to be in it or the engine is handed ids it never sees.
        repeaterSourcesProvider.overrideWithValue(sources),
        channelSuggestionServiceProvider.overrideWithValue(
          ChannelSuggestionService(
            sources: sources,
            cache: _noCache(),
            bundled: _FakeBundledData(),
          ),
        ),
      ],
      child: MaterialApp(home: RadioSuggestionScreen(profile: profile)),
    ),
  );
  await tester.pumpAndSettle();
  return sharedPrefs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('asks where you are before fetching anything', (tester) async {
    final source = FakeRepeaterSource(id: 'test');
    await _pump(tester, location: FakeLocationService(), sources: [source]);

    expect(find.text('Where are you?'), findsOneWidget);
    expect(find.text('Use my location'), findsOneWidget);
    expect(find.text('Enter by hand'), findsOneWidget);
    // Opening the screen must not start a search.
    expect(source.fetched, isEmpty);
    expect(find.text('Find channels'), findsNothing);
  });

  testWidgets('a GPS fix names the place and enables the search', (
    tester,
  ) async {
    await _pump(tester, location: FakeLocationService(position: _hartford));

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(find.text('Connecticut'), findsOneWidget);
    expect(find.text('Find channels'), findsOneWidget);
  });

  testWidgets('a refusal explains itself and still offers manual entry', (
    tester,
  ) async {
    await _pump(tester, location: FakeLocationService.denied());

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Location permission denied'), findsOneWidget);
    expect(find.textContaining('by hand'), findsWidgets);
    expect(find.text('Enter by hand'), findsOneWidget);
  });

  testWidgets('a platform with no backend is not an error the user caused', (
    tester,
  ) async {
    // Which is every Linux desktop run.
    await _pump(tester, location: FakeLocationService.unavailable());

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot report its position'), findsOneWidget);
  });

  group('entering a position by hand', () {
    testWidgets('accepts a grid square', (tester) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Grid square'),
        'FN31pr',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.text('Connecticut'), findsOneWidget);
    });

    testWidgets('accepts coordinates', (tester) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Latitude'),
        '41.7658',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Longitude'),
        '-72.6734',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.text('Connecticut'), findsOneWidget);
    });

    testWidgets('rejects a grid square that is not one', (tester) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Grid square'),
        'ZZ99zz',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.textContaining('not a grid square'), findsOneWidget);
    });

    testWidgets('rejects coordinates off the earth', (tester) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '200');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '0');
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Latitude runs'), findsOneWidget);
    });

    testWidgets('says what it needs when nothing usable was typed', (
      tester,
    ) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter a grid square'), findsOneWidget);
    });
  });

  group('results', () {
    Future<void> search(WidgetTester tester) async {
      await tester.tap(find.text('Use my location'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find channels'));
      await tester.pumpAndSettle();
    }

    testWidgets('groups them, and always includes the offline tier', (
      tester,
    ) async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [_repeater('W1AW', 146940000, 146340000)],
        },
      );
      await _pump(
        tester,
        location: FakeLocationService(position: _hartford),
        sources: [source],
      );
      await search(tester);

      expect(find.textContaining('Repeaters (1)'), findsOneWidget);
      expect(find.textContaining('Weather (7)'), findsOneWidget);
      expect(find.textContaining('Standard channels'), findsOneWidget);
      expect(find.text('W1AW'), findsOneWidget);
    });

    testWidgets('a source that needs setting up offers the way there', (
      tester,
    ) async {
      final unconfigured = FakeRepeaterSource(
        id: 'repeaterbook',
        configured: false,
      );
      await _pump(
        tester,
        location: FakeLocationService(position: _hartford),
        sources: [unconfigured],
      );
      await search(tester);

      expect(find.text('Set up'), findsOneWidget);
      // ...and the rest of the results are still there.
      expect(find.textContaining('Weather (7)'), findsOneWidget);
    });

    testWidgets('selecting channels reveals the add bar', (tester) async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [_repeater('W1AW', 146940000, 146340000)],
        },
      );
      await _pump(
        tester,
        location: FakeLocationService(position: _hartford),
        sources: [source],
      );
      await search(tester);

      expect(find.textContaining('Add '), findsNothing);
      await tester.tap(find.text('W1AW'));
      await tester.pumpAndSettle();
      expect(find.text('Add 1 channel'), findsOneWidget);
    });

    testWidgets('select-all ticks a whole group', (tester) async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [
            _repeater('W1AW', 146940000, 146340000),
            _repeater('W1XYZ', 147000000, 146400000),
          ],
        },
      );
      await _pump(
        tester,
        location: FakeLocationService(position: _hartford),
        sources: [source],
      );
      await search(tester);

      await tester.tap(find.widgetWithText(TextButton, 'All').first);
      await tester.pumpAndSettle();
      expect(find.text('Add 2 channels'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'None').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Add '), findsNothing);
    });

    testWidgets('adding creates a first plan and reports what landed', (
      tester,
    ) async {
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [_repeater('W1AW', 146940000, 146340000)],
        },
      );
      await _pump(
        tester,
        location: FakeLocationService(position: _hartford),
        sources: [source],
      );
      await search(tester);

      await tester.tap(find.text('W1AW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 channel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Added 1'), findsOneWidget);
    });

    testWidgets('keeps only the rounded position, and forgetting it clears '
        'the screen', (tester) async {
      // Regression: the screen kept its own copy of the exact fix, shown to
      // four places and preferred over the remembered one, so 'Forget
      // location' on the Repeater sources screen left the old precise point
      // shown and searched from on the way back.
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [_repeater('W1AW', 146940000, 146340000)],
        },
      );
      final gps = FakeLocationService(position: _hartford);
      await _pump(tester, location: gps, sources: [source]);
      await search(tester);
      await tester.tap(find.text('W1AW'));
      await tester.pumpAndSettle();

      expect(find.text('41.77, -72.67'), findsOneWidget);
      expect(find.textContaining('41.7658'), findsNothing);
      expect(find.text('Add 1 channel'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(RadioSuggestionScreen)),
      );
      await container.read(lastLocationProvider.notifier).forget();
      await tester.pumpAndSettle();

      expect(find.text('Where are you?'), findsOneWidget);
      expect(find.text('Connecticut'), findsNothing);
      expect(find.textContaining('41.77'), findsNothing);
      expect(find.text('Find channels'), findsNothing);
      expect(find.text('W1AW'), findsNothing, reason: 'results went too');
      expect(find.text('Add 1 channel'), findsNothing);

      // The next search asks for a position again.
      expect(gps.positionCalls, 1);
      await search(tester);
      expect(gps.positionCalls, 2);
      expect(find.text('W1AW'), findsOneWidget);
    });

    testWidgets('a plan made from a remembered position is named for it', (
      tester,
    ) async {
      // Regression: a return visit searches from the remembered position
      // without "Use my location", and the plan it made was "Near me"
      // while the location tile said Connecticut.
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [_repeater('W1AW', 146940000, 146340000)],
        },
      );
      final prefs = await _pump(
        tester,
        location: FakeLocationService(),
        sources: [source],
        settings: InMemorySettingsStore({
          LastLocationNotifier.key: jsonEncode({
            'lat': _hartford.lat,
            'lon': _hartford.lon,
            'label': 'Connecticut',
          }),
        }),
      );
      await tester.tap(find.text('Find channels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('W1AW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 channel'));
      await tester.pumpAndSettle();

      expect(ChannelPlanStore(prefs).load().single.name, 'Near Connecticut');
    });

    group('with plans for more than one radio', () {
      // Every suggestion's listen-only decision was made against the screen's
      // radio, so a plan for another radio must never be on offer: a 2 m
      // repeater judged transmittable for a UV-5R would land transmit-enabled
      // in the GMRS radio's plan.
      final mine = _plan('p-uv5r', 'Mine', uv5rProfile);
      final gmrs = _plan('p-gmrs', 'GMRS truck', uv5gProfile);

      Future<SharedPreferences> pickW1AW(
        WidgetTester tester,
        List<ChannelPlan> plans,
      ) async {
        final source = FakeRepeaterSource(
          id: 'test',
          byState: {
            'CT': [_repeater('W1AW', 146940000, 146340000)],
          },
        );
        final prefs = await _pump(
          tester,
          location: FakeLocationService(position: _hartford),
          sources: [source],
          prefs: _seedPlans(plans),
        );
        await search(tester);
        await tester.tap(find.text('W1AW'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add 1 channel'));
        await tester.pumpAndSettle();
        return prefs;
      }

      testWidgets('offers only the plans made for this radio', (tester) async {
        await pickW1AW(tester, [mine, gmrs]);

        expect(find.text('Add to which plan?'), findsOneWidget);
        expect(find.text('Mine'), findsOneWidget);
        expect(find.text('GMRS truck'), findsNothing);
      });

      testWidgets('and the channels land in the one picked', (tester) async {
        final prefs = await pickW1AW(tester, [mine, gmrs]);
        await tester.tap(find.text('Mine'));
        await tester.pumpAndSettle();

        expect(find.textContaining('Added 1 to "Mine"'), findsOneWidget);
        final stored = {
          for (final plan in ChannelPlanStore(prefs).load()) plan.id: plan,
        };
        expect(stored['p-uv5r']!.channels.single.name, 'W1AW');
        expect(stored['p-gmrs']!.channels, isEmpty);
      });

      testWidgets('a plan for another radio alone gets a new one made', (
        tester,
      ) async {
        // The same as having no plans at all: no sheet, a fresh plan for
        // this radio, and the other radio's plan untouched.
        final prefs = await pickW1AW(tester, [gmrs]);

        expect(find.text('Add to which plan?'), findsNothing);
        expect(find.textContaining('Added 1'), findsOneWidget);
        final stored = ChannelPlanStore(prefs).load();
        expect(stored, hasLength(2));
        final made = stored.singleWhere((p) => p.id != 'p-gmrs');
        expect(made.radioProfileId, uv5rProfile.id);
        expect(made.channels.single.name, 'W1AW');
        expect(stored.singleWhere((p) => p.id == 'p-gmrs').channels, isEmpty);
      });
    });

    testWidgets('a listen-only suggestion is badged before it is picked', (
      tester,
    ) async {
      // 155 MHz: inside the UV-5R's receive range, outside its transmit one.
      final source = FakeRepeaterSource(
        id: 'test',
        byState: {
          'CT': [_repeater('PUBLIC', 155000000, 155000000)],
        },
      );
      await _pump(
        tester,
        location: FakeLocationService(position: _hartford),
        sources: [source],
      );
      await search(tester);

      expect(find.text('Listen only'), findsWidgets);
    });
  });
}
