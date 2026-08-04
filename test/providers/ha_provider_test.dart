// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';
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

/// Distinctive filler for the secret parts of a config, so a leak of any
/// window of the stored blob is unmistakable in an assertion.
const _secretMarker = 'SECRETTOKENMATERIAL';

/// The exception `jsonDecode` throws for [raw] — i.e. the object the previous
/// `debugPrint('...: $e')` interpolated straight into the log.
Object _decodeFailure(String raw) {
  try {
    jsonDecode(raw);
  } catch (e) {
    return e;
  }
  throw StateError('expected a decode failure for: $raw');
}

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

    test('a corrupt config never leaks token material into the log', () async {
      // The blob this branch exists to handle is the DECRYPTED config: the
      // long-lived access token and the webhook id.
      final blob = jsonEncode(const HaConfig(
        baseUrl: 'http://ha.local:8123',
        token: 'lltok-$_secretMarker-$_secretMarker',
        deviceId: 'dev1',
        webhookId: 'wh-$_secretMarker',
      ).toJson());
      // Truncated mid-token, which is exactly the case the branch names.
      final corrupt = blob.substring(0, blob.indexOf(_secretMarker) + 40);

      // The hazard is real, not hypothetical: FormatException.toString()
      // quotes a window of its source around the failure offset, so the
      // exception object itself carries token material. Interpolating it -
      // which is what this code used to do - put that in the log.
      expect('${_decodeFailure(corrupt)}', contains(_secretMarker));

      final records = Log.captureRecords();
      addTearDown(Log.reset);
      final store =
          InMemorySettingsStore({HaConfigNotifier.configKey: corrupt});

      expect(await _loadConfig(store), isNull);

      // We still say what happened, by type...
      final logged = records.map((r) => r.format()).join('\n');
      expect(logged, contains('FormatException'));
      expect(logged, contains('corrupt'));
      // ...but no part of the secret reaches the log.
      expect(logged, isNot(contains(_secretMarker)));
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

    test('the log records the base url but never the token or webhook',
        () async {
      final records = Log.captureRecords();
      addTearDown(Log.reset);
      final container = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
          haApiClientProvider.overrideWithValue(FakeHaApiClient()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(haConfigProvider.future);

      await container.read(haConfigProvider.notifier).register(
          baseUrl: 'http://ha.local:8123', token: 'lltok-$_secretMarker');

      final logged = records.map((r) => r.format()).join('\n');
      expect(logged, contains('http://ha.local:8123'));
      expect(logged, isNot(contains(_secretMarker)));
      expect(logged, contains('<redacted>'));
    });
  });
}
