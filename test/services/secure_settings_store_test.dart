// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';

void main() {
  // These options are load-bearing (see the comments on the constants):
  // changing the Android backend strands stored tokens, dropping resetOnError
  // re-introduces read crashes after key invalidation, and a stricter iOS
  // accessibility breaks background forwarding. Asserted via `params` because
  // flutter_secure_storage keeps the option fields private.
  test('Android keeps the EncryptedSharedPreferences backend + resetOnError',
      () {
    final params = SecureSettingsStore.androidOptions.params;
    expect(params['encryptedSharedPreferences'], 'true');
    expect(params['resetOnError'], 'true');
  });

  test(
      'iOS keychain items are readable after the first post-boot unlock, '
      'and never leave this device', () {
    final params = SecureSettingsStore.iosOptions.params;
    expect(
      params['accessibility'],
      KeychainAccessibility.first_unlock_this_device.name,
      reason: 'first_unlock (not `unlocked`) because the sensor forwarder '
          'reads the HA token in the background on a locked phone. '
          '_this_device because the plain class is included in encrypted '
          'iTunes/iCloud backups and restored onto ANOTHER device — and every '
          'secret here (HA token, Hue client key, Roomba local password, '
          'Rabbit Air AES key, TLS pins) is scoped to hardware on one LAN.',
    );
  });

  group('a fresh install does not inherit the last one\'s credentials', () {
    test('wipes and marks when the install marker is absent', () async {
      final storage = _RecordingStorage();
      final store = SecureSettingsStore(storage);
      var marked = false;

      final wiped = await store.wipeIfFreshInstall(
        hasRun: () async => false,
        markRun: () async => marked = true,
      );

      expect(wiped, isTrue);
      expect(storage.deleteAllCalls, 1,
          reason: 'The iOS keychain survives app deletion, so a reinstall '
              'starts with the previous install\'s secrets and a Terms gate '
              'that has reset. Clearing it is the whole point.');
      expect(marked, isTrue,
          reason: 'Without the marker the wipe would repeat on every launch '
              'and the app could never keep a credential at all.');
    });

    test('does nothing on a subsequent launch', () async {
      final storage = _RecordingStorage();
      final store = SecureSettingsStore(storage);
      var marked = false;

      final wiped = await store.wipeIfFreshInstall(
        hasRun: () async => true,
        markRun: () async => marked = true,
      );

      expect(wiped, isFalse);
      expect(storage.deleteAllCalls, 0);
      expect(marked, isFalse);
    });

    test('a keychain that will not clear does not stop the app launching',
        () async {
      final store = SecureSettingsStore(_ThrowingStorage());

      await expectLater(
        store.wipeIfFreshInstall(
          hasRun: () async => false,
          markRun: () async {},
        ),
        completion(isFalse),
        reason: 'This runs before runApp. Throwing here would turn a keychain '
            'problem into an app that does not start.',
      );
    });
  });
}

/// Counts deleteAll(); everything else is unused by these tests.
class _RecordingStorage extends FlutterSecureStorage {
  _RecordingStorage() : super();
  int deleteAllCalls = 0;

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      deleteAllCalls++;
}

class _ThrowingStorage extends FlutterSecureStorage {
  _ThrowingStorage() : super();

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      throw StateError('keychain unavailable');
}
