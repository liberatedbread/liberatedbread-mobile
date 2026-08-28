// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
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
          boxes: [
            (
              minLat: 40.98,
              minLon: -73.73,
              maxLat: 42.05,
              maxLon: -71.79,
            )
          ],
        ),
      ];
}

/// A cache with nowhere to write, so every read misses and every write is a
/// no-op. [RadioSourceCache] already degrades that way by design.
RadioSourceCache _noCache() => RadioSourceCache(
      cacheDirResolver: () async =>
          throw StateError('no cache in widget tests'),
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
}) async {
  _useTallWindow(tester);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      prefsSettingsStoreProvider
          .overrideWith((ref) async => InMemorySettingsStore()),
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
  ));
  await tester.pumpAndSettle();
  return prefs;
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

  testWidgets('a GPS fix names the place and enables the search',
      (tester) async {
    await _pump(tester, location: FakeLocationService(position: _hartford));

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(find.text('Connecticut'), findsOneWidget);
    expect(find.text('Find channels'), findsOneWidget);
  });

  testWidgets('a refusal explains itself and still offers manual entry',
      (tester) async {
    await _pump(tester, location: FakeLocationService.denied());

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Location permission denied'), findsOneWidget);
    expect(find.textContaining('by hand'), findsWidgets);
    expect(find.text('Enter by hand'), findsOneWidget);
  });

  testWidgets('a platform with no backend is not an error the user caused',
      (tester) async {
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
          find.widgetWithText(TextField, 'Grid square'), 'FN31pr');
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.text('Connecticut'), findsOneWidget);
    });

    testWidgets('accepts coordinates', (tester) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Latitude'), '41.7658');
      await tester.enterText(
          find.widgetWithText(TextField, 'Longitude'), '-72.6734');
      await tester.tap(find.widgetWithText(FilledButton, 'Use this'));
      await tester.pumpAndSettle();

      expect(find.text('Connecticut'), findsOneWidget);
    });

    testWidgets('rejects a grid square that is not one', (tester) async {
      await _pump(tester, location: FakeLocationService());

      await tester.tap(find.text('Enter by hand'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Grid square'), 'ZZ99zz');
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

    testWidgets('says what it needs when nothing usable was typed',
        (tester) async {
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

    testWidgets('groups them, and always includes the offline tier',
        (tester) async {
      final source = FakeRepeaterSource(id: 'test', byState: {
        'CT': [_repeater('W1AW', 146940000, 146340000)],
      });
      await _pump(tester,
          location: FakeLocationService(position: _hartford),
          sources: [source]);
      await search(tester);

      expect(find.textContaining('Repeaters (1)'), findsOneWidget);
      expect(find.textContaining('Weather (7)'), findsOneWidget);
      expect(find.textContaining('Standard channels'), findsOneWidget);
      expect(find.text('W1AW'), findsOneWidget);
    });

    testWidgets('a source that needs setting up offers the way there',
        (tester) async {
      final unconfigured =
          FakeRepeaterSource(id: 'repeaterbook', configured: false);
      await _pump(tester,
          location: FakeLocationService(position: _hartford),
          sources: [unconfigured]);
      await search(tester);

      expect(find.text('Set up'), findsOneWidget);
      // ...and the rest of the results are still there.
      expect(find.textContaining('Weather (7)'), findsOneWidget);
    });

    testWidgets('selecting channels reveals the add bar', (tester) async {
      final source = FakeRepeaterSource(id: 'test', byState: {
        'CT': [_repeater('W1AW', 146940000, 146340000)],
      });
      await _pump(tester,
          location: FakeLocationService(position: _hartford),
          sources: [source]);
      await search(tester);

      expect(find.textContaining('Add '), findsNothing);
      await tester.tap(find.text('W1AW'));
      await tester.pumpAndSettle();
      expect(find.text('Add 1 channel'), findsOneWidget);
    });

    testWidgets('select-all ticks a whole group', (tester) async {
      final source = FakeRepeaterSource(id: 'test', byState: {
        'CT': [
          _repeater('W1AW', 146940000, 146340000),
          _repeater('W1XYZ', 147000000, 146400000),
        ],
      });
      await _pump(tester,
          location: FakeLocationService(position: _hartford),
          sources: [source]);
      await search(tester);

      await tester.tap(find.widgetWithText(TextButton, 'All').first);
      await tester.pumpAndSettle();
      expect(find.text('Add 2 channels'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'None').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Add '), findsNothing);
    });

    testWidgets('adding creates a first plan and reports what landed',
        (tester) async {
      final source = FakeRepeaterSource(id: 'test', byState: {
        'CT': [_repeater('W1AW', 146940000, 146340000)],
      });
      await _pump(tester,
          location: FakeLocationService(position: _hartford),
          sources: [source]);
      await search(tester);

      await tester.tap(find.text('W1AW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 channel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Added 1'), findsOneWidget);
    });

    testWidgets('a listen-only suggestion is badged before it is picked',
        (tester) async {
      // 155 MHz: inside the UV-5R's receive range, outside its transmit one.
      final source = FakeRepeaterSource(id: 'test', byState: {
        'CT': [_repeater('PUBLIC', 155000000, 155000000)],
      });
      await _pump(tester,
          location: FakeLocationService(position: _hartford),
          sources: [source]);
      await search(tester);

      expect(find.text('Listen only'), findsWidgets);
    });
  });
}
