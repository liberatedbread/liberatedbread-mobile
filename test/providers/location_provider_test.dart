// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/providers/location_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/services/location_service.dart';

import '../fakes/fake_location_service.dart';
import '../fakes/in_memory_settings_store.dart';

ProviderContainer _container(InMemorySettingsStore store) {
  final container = ProviderContainer(overrides: [
    prefsSettingsStoreProvider.overrideWith((ref) async => store),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  const key = LastLocationNotifier.key;
  const seattle = GeoPoint(47.6062, -122.3321);

  group('SavedLocation', () {
    test('round-trips through JSON', () {
      const location = SavedLocation(point: seattle, label: 'Seattle, WA');
      final decoded = SavedLocation.fromJson(
          jsonDecode(jsonEncode(location.toJson())) as Map<String, dynamic>);
      expect(decoded, location);
      expect(decoded.hashCode, location.hashCode);
    });

    test('invents a label rather than showing a blank one', () {
      final decoded =
          SavedLocation.fromJson(const {'lat': 47.6062, 'lon': -122.3321});
      expect(decoded!.label, '47.6062, -122.3321');
      expect(
        SavedLocation.fromJson(
                const {'lat': 47.6062, 'lon': -122.3321, 'label': '   '})!
            .label,
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
            const SavedLocation(point: seattle, label: 'Seattle').toJson()),
      });
      final location =
          await _container(store).read(lastLocationProvider.future);
      expect(location!.point, seattle);
      expect(location.label, 'Seattle');
    });

    test('a corrupt stored location reads as none, not as a crash', () async {
      // This runs on the Radio tab's first frame. A location nobody can read
      // is a location nobody had.
      for (final corrupt in ['not json', '[]', '{}', '{"lat": "north"}']) {
        final store = InMemorySettingsStore({key: corrupt});
        expect(
            await _container(store).read(lastLocationProvider.future), isNull,
            reason: corrupt);
      }
    });

    test('remember persists and updates the state', () async {
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(lastLocationProvider.future);

      const location = SavedLocation(point: seattle, label: 'Seattle');
      await container.read(lastLocationProvider.notifier).remember(location);

      expect(container.read(lastLocationProvider).value, location);
      expect(store.values[key], isNotNull);
      // ...and survives a fresh container reading the same store.
      expect(
          await _container(store).read(lastLocationProvider.future), location);
    });

    test('forget clears both the state and the store', () async {
      final store = InMemorySettingsStore({
        key: jsonEncode(
            const SavedLocation(point: seattle, label: 'Seattle').toJson()),
      });
      final container = _container(store);
      await container.read(lastLocationProvider.future);

      await container.read(lastLocationProvider.notifier).forget();

      expect(container.read(lastLocationProvider).value, isNull);
      expect(store.values.containsKey(key), isFalse);
    });
  });

  group('locationServiceProvider', () {
    test('provides a real service by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(locationServiceProvider), isA<LocationService>());
    });

    test('is overridable, which is how every screen test gets a fix', () {
      final fake = FakeLocationService();
      final container = ProviderContainer(overrides: [
        locationServiceProvider.overrideWithValue(fake),
      ]);
      addTearDown(container.dispose);
      expect(container.read(locationServiceProvider), same(fake));
    });
  });

  group('FakeLocationService', () {
    test('answers a fix and counts the asking', () async {
      final fake = FakeLocationService();
      expect(await fake.gpsAvailable(), isTrue);
      expect(await fake.currentPosition(), fake.position);
      expect(fake.positionCalls, 1);
      expect(fake.availabilityCalls, 1);
    });

    test('models a refusal', () async {
      final fake = FakeLocationService.denied();
      await expectLater(fake.currentPosition(),
          throwsA(isA<LocationPermissionDeniedException>()));
    });

    test('models a platform with no backend', () async {
      final fake = FakeLocationService.unavailable();
      expect(await fake.gpsAvailable(), isFalse);
      await expectLater(
          fake.currentPosition(), throwsA(isA<LocationUnavailableException>()));
    });
  });
}
