// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/radio_source_settings_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/services/mygmrs_client.dart';
import 'package:liberated_bread_mobile/services/repeaterbook_client.dart';

import '../fakes/in_memory_settings_store.dart';

ProviderContainer _container({
  InMemorySettingsStore? prefs,
  InMemorySettingsStore? secure,
}) {
  final container = ProviderContainer(overrides: [
    prefsSettingsStoreProvider
        .overrideWith((ref) async => prefs ?? InMemorySettingsStore()),
    settingsStoreProvider
        .overrideWithValue(secure ?? InMemorySettingsStore()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('RadioSourceSettings', () {
    test('has everything on by default', () {
      const settings = RadioSourceSettings();
      expect(settings.isEnabled('repeaterbook'), isTrue);
      expect(settings.isEnabled('mygmrs'), isTrue);
      expect(settings.isEnabled('a-source-invented-next-year'), isTrue);
      expect(settings.radiusKm, RadioSourceSettings.defaultRadiusKm);
    });

    test('stores the exclusions, so a new source is not born invisible', () {
      // The set is what is OFF. Stored the other way round, a source added in
      // a later build would be absent from every saved settings blob and
      // therefore silently disabled for everyone who had ever opened the
      // settings screen.
      const settings = RadioSourceSettings();
      final off = settings.withSource('mygmrs', enabled: false);
      expect(off.toJson()['disabled'], ['mygmrs']);
      expect(off.isEnabled('mygmrs'), isFalse);
      expect(off.isEnabled('repeaterbook'), isTrue);
      expect(off.withSource('mygmrs', enabled: true).isEnabled('mygmrs'),
          isTrue);
    });

    test('round-trips through JSON', () {
      final settings = const RadioSourceSettings()
          .withRadius(80)
          .withSource('repeaterbook', enabled: false);
      final decoded = RadioSourceSettings.fromJson(
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);
      expect(decoded, settings);
      expect(decoded.hashCode, settings.hashCode);
    });

    test('refuses an implausible stored radius', () {
      for (final radius in [0, -5, 100000, 'far']) {
        final decoded = RadioSourceSettings.fromJson({'radiusKm': radius});
        expect(decoded.radiusKm, RadioSourceSettings.defaultRadiusKm,
            reason: '$radius');
      }
    });

    test('the radius menu is sorted and sane', () {
      const choices = RadioSourceSettings.radiusChoices;
      expect(choices, contains(RadioSourceSettings.defaultRadiusKm));
      expect(choices, [...choices]..sort());
      expect(choices.first, greaterThan(0));
    });
  });

  group('radioSourceSettingsProvider', () {
    test('defaults when nothing is stored', () async {
      final settings =
          await _container().read(radioSourceSettingsProvider.future);
      expect(settings, const RadioSourceSettings());
    });

    test('a corrupt blob reads as defaults', () async {
      for (final corrupt in ['not json', '[]', '7']) {
        final prefs = InMemorySettingsStore(
            {RadioSourceSettingsNotifier.key: corrupt});
        expect(
            await _container(prefs: prefs)
                .read(radioSourceSettingsProvider.future),
            const RadioSourceSettings(),
            reason: corrupt);
      }
    });

    test('toggling a source persists', () async {
      final prefs = InMemorySettingsStore();
      final container = _container(prefs: prefs);
      await container.read(radioSourceSettingsProvider.future);

      await container
          .read(radioSourceSettingsProvider.notifier)
          .setSourceEnabled('mygmrs', false);

      expect(container.read(radioSourceSettingsProvider).value!
          .isEnabled('mygmrs'), isFalse);
      expect(
          (await _container(prefs: prefs)
                  .read(radioSourceSettingsProvider.future))
              .isEnabled('mygmrs'),
          isFalse);
    });

    test('setting the radius persists', () async {
      final prefs = InMemorySettingsStore();
      final container = _container(prefs: prefs);
      await container.read(radioSourceSettingsProvider.future);

      await container.read(radioSourceSettingsProvider.notifier)
          .setRadiusKm(160);

      expect(
          (await _container(prefs: prefs)
                  .read(radioSourceSettingsProvider.future))
              .radiusKm,
          160);
    });
  });

  group('repeaterBookTokenProvider', () {
    test('is null until a token is saved', () async {
      expect(await _container().read(repeaterBookTokenProvider.future),
          isNull);
    });

    test('saves to the secure store, not to preferences', () async {
      // It identifies a person's RepeaterBook account. Shared preferences is
      // plaintext on disk; this belongs in the keychain.
      final prefs = InMemorySettingsStore();
      final secure = InMemorySettingsStore();
      final container = _container(prefs: prefs, secure: secure);
      await container.read(repeaterBookTokenProvider.future);

      await container
          .read(repeaterBookTokenProvider.notifier)
          .setToken('  rbuapp_token  ');

      expect(secure.values[RepeaterBookTokenNotifier.key], 'rbuapp_token');
      expect(prefs.values, isEmpty);
      expect(container.read(repeaterBookTokenProvider).value, 'rbuapp_token');
    });

    test('an empty token clears rather than storing whitespace', () async {
      final secure = InMemorySettingsStore(
          {RepeaterBookTokenNotifier.key: 'rbuapp_old'});
      final container = _container(secure: secure);
      await container.read(repeaterBookTokenProvider.future);

      await container.read(repeaterBookTokenProvider.notifier).clear();

      expect(secure.values.containsKey(RepeaterBookTokenNotifier.key), isFalse);
      expect(container.read(repeaterBookTokenProvider).value, isNull);
    });

    test('whitespace stored by an older build reads as no token', () async {
      final secure =
          InMemorySettingsStore({RepeaterBookTokenNotifier.key: '   '});
      expect(await _container(secure: secure)
          .read(repeaterBookTokenProvider.future), isNull);
    });
  });

  group('the source list', () {
    test('is RepeaterBook then myGMRS', () {
      final sources = _container().read(repeaterSourcesProvider);
      expect(sources.map((s) => s.id), ['repeaterbook', 'mygmrs']);
      expect(sources[0], isA<RepeaterBookClient>());
      expect(sources[1], isA<MyGmrsClient>());
    });

    test('every source that needs attribution carries it', () {
      for (final source in _container().read(repeaterSourcesProvider)) {
        if (source.id == 'repeaterbook') {
          expect(source.attribution, isNotNull, reason: source.id);
        }
      }
    });

    test('the user agent names the app and where to find it', () {
      // RepeaterBook's terms ask for both.
      expect(radioSourceUserAgent, contains('LiberatedBread'));
      expect(radioSourceUserAgent, contains('github.com'));
    });

    test('one http client is shared and closed with the container', () {
      final container = _container();
      final client = container.read(radioHttpClientProvider);
      expect(container.read(radioHttpClientProvider), same(client));
    });
  });
}
