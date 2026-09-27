// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/providers/location_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/services/location_service.dart';

import '../fakes/in_memory_settings_store.dart';

ProviderContainer _container(InMemorySettingsStore store) {
  final container = ProviderContainer(
    overrides: [prefsSettingsStoreProvider.overrideWith((ref) async => store)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  const key = LastLocationNotifier.key;
  const seattle = GeoPoint(47.6062, -122.3321);
  // What LastLocationNotifier keeps of [seattle]: two decimals, about 1 km.
  const seattleCoarse = GeoPoint(47.61, -122.33);

  group('SavedLocation', () {
    test('round-trips through JSON', () {
      const location = SavedLocation(point: seattle, label: 'Seattle, WA');
      final decoded = SavedLocation.fromJson(
        jsonDecode(jsonEncode(location.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, location);
      expect(decoded.hashCode, location.hashCode);
    });

    test('invents a label rather than showing a blank one', () {
      final decoded = SavedLocation.fromJson(const {
        'lat': 47.6062,
        'lon': -122.3321,
      });
      expect(decoded!.label, '47.6062, -122.3321');
      expect(
        SavedLocation.fromJson(const {
          'lat': 47.6062,
          'lon': -122.3321,
          'label': '   ',
        })!.label,
        isNotEmpty,
      );
    });

    test('rejects a record with no usable position', () {
      expect(SavedLocation.fromJson(const {'label': 'nowhere'}), isNull);
      expect(SavedLocation.fromJson(const {'lat': 'north', 'lon': 0}), isNull);
    });
  });

  group('lastLocationProvider', () {
    test('is null before the user has searched anywhere', () async {
      final container = _container(InMemorySettingsStore());
      expect(await container.read(lastLocationProvider.future), isNull);
    });

    test('reads back what was stored', () async {
      final store = InMemorySettingsStore({
        key: jsonEncode(
          const SavedLocation(point: seattleCoarse, label: 'Seattle').toJson(),
        ),
      });
      final location = await _container(
        store,
      ).read(lastLocationProvider.future);
      expect(location!.point, seattleCoarse);
      expect(location.label, 'Seattle');
    });

    test('a corrupt stored location reads as none, not as a crash', () async {
      // This runs on the Radio tab's first frame. A location nobody can read
      // is a location nobody had.
      for (final corrupt in ['not json', '[]', '{}', '{"lat": "north"}']) {
        final store = InMemorySettingsStore({key: corrupt});
        expect(
          await _container(store).read(lastLocationProvider.future),
          isNull,
          reason: corrupt,
        );
      }
    });

    test('remember persists and updates the state', () async {
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(lastLocationProvider.future);

      const location = SavedLocation(point: seattleCoarse, label: 'Seattle');
      await container.read(lastLocationProvider.notifier).remember(location);

      expect(container.read(lastLocationProvider).value, location);
      expect(store.values[key], isNotNull);
      // ...and survives a fresh container reading the same store.
      expect(
        await _container(store).read(lastLocationProvider.future),
        location,
      );
    });

    test('remember keeps about a kilometre, not the exact fix', () async {
      // The record outlives the search, sits in plain preferences and rides
      // device backups. It used to hold the GPS fix to full precision, which
      // for most users is their front door.
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(lastLocationProvider.future);

      await container
          .read(lastLocationProvider.notifier)
          .remember(
            const SavedLocation(
              point: GeoPoint(47.620422, -122.349358),
              label: 'Washington',
            ),
          );

      final stored = jsonDecode(store.values[key]!) as Map<String, dynamic>;
      expect(stored['lat'], 47.62);
      expect(stored['lon'], -122.35);
      expect(stored['label'], 'Washington');
      // Memory and disk agree, so the screen never shows a finer point than
      // the one that would come back after a restart.
      expect(
        container.read(lastLocationProvider).value!.point,
        const GeoPoint(47.62, -122.35),
      );
    });

    test(
      'a precise fix stored by an older build is rewritten rounded',
      () async {
        final store = InMemorySettingsStore({
          key: jsonEncode(
            const SavedLocation(
              point: GeoPoint(47.620422, -122.349358),
              label: 'Washington',
            ).toJson(),
          ),
        });

        final location = await _container(
          store,
        ).read(lastLocationProvider.future);

        expect(location!.point, const GeoPoint(47.62, -122.35));
        final stored = jsonDecode(store.values[key]!) as Map<String, dynamic>;
        expect(stored['lat'], 47.62);
        expect(stored['lon'], -122.35);
      },
    );

    test('forget removes it from disk and from memory', () async {
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(lastLocationProvider.future);
      final notifier = container.read(lastLocationProvider.notifier);
      await notifier.remember(
        const SavedLocation(point: seattleCoarse, label: 'Seattle'),
      );

      await notifier.forget();

      expect(store.values.containsKey(key), isFalse);
      expect(container.read(lastLocationProvider).value, isNull);
      expect(await _container(store).read(lastLocationProvider.future), isNull);
    });
  });

  group('locationServiceProvider', () {
    test('provides a real service by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(locationServiceProvider), isA<LocationService>());
    });
  });
}
