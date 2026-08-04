// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';

import '../fakes/fake_spec_pack_service.dart';
import '../fakes/in_memory_settings_store.dart';

/// A service whose cache read blows up, to exercise the provider's
/// degrade-to-empty catch (device matching must survive on bundled specs).
class _ThrowingSpecPackService extends FakeSpecPackService {
  @override
  Future<Map<String, String>> loadCachedSpecs() async =>
      throw StateError('cache unreadable');
}

ProviderContainer _container(InMemorySettingsStore store) {
  final container = ProviderContainer(overrides: [
    prefsSettingsStoreProvider.overrideWith((ref) async => store),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  const key = SpecPackUrlNotifier.key;
  const customUrl = 'https://example.com/pack.json';

  group('specPackUrlProvider', () {
    test('build() returns the default URL when the store is empty', () async {
      final container = _container(InMemorySettingsStore());
      expect(
        await container.read(specPackUrlProvider.future),
        AppConstants.defaultSpecPackUrl,
      );
    });

    test('build() returns the saved URL when present', () async {
      final container = _container(InMemorySettingsStore({key: customUrl}));
      expect(await container.read(specPackUrlProvider.future), customUrl);
    });

    test('whitespace-only stored value maps to the default', () async {
      final container = _container(InMemorySettingsStore({key: '   '}));
      expect(
        await container.read(specPackUrlProvider.future),
        AppConstants.defaultSpecPackUrl,
      );
    });

    test('resetToDefault() persists and exposes the default', () async {
      final store = InMemorySettingsStore({key: customUrl});
      final container = _container(store);
      await container.read(specPackUrlProvider.future);

      await container.read(specPackUrlProvider.notifier).resetToDefault();

      expect(store.values.containsKey(key), isFalse);
      expect(
        await container.read(specPackUrlProvider.future),
        AppConstants.defaultSpecPackUrl,
      );
    });

    test('setUrl(valid) persists the trimmed URL', () async {
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(specPackUrlProvider.future);

      await container
          .read(specPackUrlProvider.notifier)
          .setUrl('  $customUrl  ');

      expect(store.values[key], customUrl);
      expect(await container.read(specPackUrlProvider.future), customUrl);
    });

    test('setUrl of empty/whitespace input behaves as a reset', () async {
      final store = InMemorySettingsStore({key: customUrl});
      final container = _container(store);
      await container.read(specPackUrlProvider.future);

      await container.read(specPackUrlProvider.notifier).setUrl('   ');

      // Disk and memory agree: no stored override, default exposed. (Before,
      // '' was persisted and exposed while build() would map it back to the
      // default on the next launch.)
      expect(store.values.containsKey(key), isFalse);
      expect(
        await container.read(specPackUrlProvider.future),
        AppConstants.defaultSpecPackUrl,
      );
    });
  });

  group('cachedSpecPacksProvider', () {
    test('a cache-read failure degrades to an empty map, not an error',
        () async {
      final container = ProviderContainer(overrides: [
        specPackServiceProvider.overrideWithValue(_ThrowingSpecPackService()),
      ]);
      addTearDown(container.dispose);

      expect(await container.read(cachedSpecPacksProvider.future), isEmpty);
    });
  });
}
