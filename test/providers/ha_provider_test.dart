// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';

import '../fakes/fake_ha_api_client.dart';
import '../fakes/in_memory_settings_store.dart';

/// A store whose reads always fail, mimicking a keystore/PlatformException
/// after an OS restore invalidated the keys.
class _ThrowingReadStore implements SettingsStore {
  final Map<String, String> values;
  final List<String> deleted = [];

  _ThrowingReadStore([Map<String, String>? initial]) : values = {...?initial};

  @override
  Future<String?> read(String key) async =>
      throw Exception('keystore read failed for $key');

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    values.remove(key);
  }
}

const _config = HaConfig(
  baseUrl: 'http://ha.local:8123',
  token: 'tok',
  deviceId: 'dev1',
  webhookId: 'wh1',
);

Future<HaConfig?> _loadConfig(SettingsStore store) async {
  final container = ProviderContainer(
    overrides: [settingsStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  return container.read(haConfigProvider.future);
}

void main() {
  group('HaConfigNotifier.build', () {
    test('returns null when nothing is stored', () async {
      expect(await _loadConfig(InMemorySettingsStore()), isNull);
    });

    test('parses a valid stored config', () async {
      final store = InMemorySettingsStore({
        HaConfigNotifier.configKey: jsonEncode(_config.toJson()),
      });
      final config = await _loadConfig(store);
      expect(config, isNotNull);
      expect(config!.webhookId, 'wh1');
      expect(config.baseUrl, 'http://ha.local:8123');
    });

    test('recovers from a truncated/non-JSON blob and clears it', () async {
      final store = InMemorySettingsStore({
        HaConfigNotifier.configKey: '{"base_url":"http://ha', // truncated
      });

      // Must not surface as an AsyncError; recovers to "not configured".
      expect(await _loadConfig(store), isNull);
      // And the corrupt value is cleared so a re-registration can overwrite it.
      expect(store.values.containsKey(HaConfigNotifier.configKey), isFalse);
    });

    test('recovers from a well-formed JSON blob with the wrong shape',
        () async {
      // Valid JSON, but base_url is missing -> `as String` TypeError.
      final store = InMemorySettingsStore({
        HaConfigNotifier.configKey: jsonEncode({'token': 'tok'}),
      });

      expect(await _loadConfig(store), isNull);
      expect(store.values.containsKey(HaConfigNotifier.configKey), isFalse);
    });

    test('recovers from a failed keystore read without clearing', () async {
      final store = _ThrowingReadStore();

      // A read failure is treated as "not configured" rather than a permanent
      // AsyncError. We do not attempt to delete on read failure (the value may
      // still be intact and become readable again after another unlock).
      expect(await _loadConfig(store), isNull);
      expect(store.deleted, isEmpty);
    });
  });

  group('HaConfigNotifier.register', () {
    test('reuses a previously stored device id', () async {
      // The device id is the app's stable identity in HA: re-registering with
      // the stored id updates the existing HA device entry instead of
      // creating a duplicate.
      final store = InMemorySettingsStore({
        HaConfigNotifier.deviceIdKey: 'preexisting-device-id',
      });
      final api = FakeHaApiClient();
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          haApiClientProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);
      await container.read(haConfigProvider.future);

      await container
          .read(haConfigProvider.notifier)
          .register(baseUrl: 'http://ha.local:8123', token: 'tok');

      expect(
          api.registeredDevices.single['device_id'], 'preexisting-device-id');
      // The stored id is untouched (not regenerated).
      expect(
          store.values[HaConfigNotifier.deviceIdKey], 'preexisting-device-id');
    });
  });
}
