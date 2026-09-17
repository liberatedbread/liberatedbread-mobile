// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('read and delete are not scoped to one accessibility class', () {
    test('the sweeping options set no accessibility at all', () {
      expect(
        SecureSettingsStore.iosOptionsAnyAccessibility.params
            .containsKey('accessibility'),
        isFalse,
        reason: 'flutter_secure_storage puts the accessibility class into the '
            'keychain QUERY, so readAll/delete/deleteAll issued with one class '
            'silently match nothing written under another. AppleOptions.toMap '
            'omits the key when accessibility is null, which is what makes the '
            'query unconstrained. If this regains a class, every item written '
            'by an older build becomes invisible and undeletable again.',
      );
      expect(
        SecureSettingsStore.iosOptions.params['accessibility'],
        KeychainAccessibility.first_unlock_this_device.name,
        reason: 'Writes still take the stronger, backup-excluded class.',
      );
    });

    test('readAll goes through the unscoped store', () async {
      final scoped = _RecordingStorage();
      final sweeping = _RecordingStorage();
      await SecureSettingsStore(scoped, sweeping).readAll();
      expect(sweeping.readAllCalls, 1);
      expect(scoped.readAllCalls, 0,
          reason: 'A class-scoped readAll is what made per-device credentials '
              'and TLS pins vanish after the write class changed.');
    });

    test('delete(key) goes through the unscoped store', () async {
      final scoped = _RecordingStorage();
      final sweeping = _RecordingStorage();
      await SecureSettingsStore(scoped, sweeping).delete('ha_token');
      expect(sweeping.deleteCalls, ['ha_token']);
      expect(scoped.deleteCalls, isEmpty,
          reason: 'The plugin puts the accessibility class into the delete '
              'query too, so a class-scoped delete cannot remove an item an '
              'earlier build wrote: "forget this device" would report '
              'success and leave the credential in the keychain.');
    });

    test('the wipe deletes through the unscoped store', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final scoped = _RecordingStorage();
      final sweeping = _RecordingStorage();
      await SecureSettingsStore(scoped, sweeping)
          .reconcileInstall(await SharedPreferences.getInstance());
      expect(sweeping.deleteAllCalls, 1);
      expect(scoped.deleteAllCalls, 0,
          reason: 'A class-scoped deleteAll cannot touch the items left by a '
              'previous install, which are the only items this wipe exists '
              'for. It would return errSecItemNotFound, which the plugin maps '
              'to success, and the marker would be written regardless.');
    });
  });

  group('an update in place is not a fresh install', () {
    test('empty preferences are a fresh install', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        SecureSettingsStore.isFreshInstall(
            await SharedPreferences.getInstance()),
        isTrue,
      );
    });

    test('accepted terms mean the app has run here before', () async {
      SharedPreferences.setMockInitialValues(
          {AppConstants.termsAcceptedKey: AppConstants.termsVersion});
      expect(
        SecureSettingsStore.isFreshInstall(
            await SharedPreferences.getInstance()),
        isFalse,
        reason: 'The marker was introduced after the app had users, so it is '
            'absent on the first launch of the build that added it — for '
            'EVERY existing install, since preferences survive an in-place '
            'update. Without a second witness that first launch wipes every '
            'credential the user has, unrecoverably. The terms gate is '
            'unskippable, so its key is the witness.',
      );
    });

    test('the marker alone is enough once it has been written', () async {
      SharedPreferences.setMockInitialValues(
          {SecureSettingsStore.freshInstallMarkerKey: true});
      expect(
        SecureSettingsStore.isFreshInstall(
            await SharedPreferences.getInstance()),
        isFalse,
      );
    });
  });

  group('a fresh install does not inherit the last one\'s credentials', () {
    test('wipes, and records the decision, when nothing has run here before',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final storage = _RecordingStorage();

      final wiped = await SecureSettingsStore(storage).reconcileInstall(prefs);

      expect(wiped, isTrue);
      expect(storage.deleteAllCalls, 1,
          reason: 'The iOS keychain survives app deletion, so a reinstall '
              'starts with the previous install\'s secrets while the Terms '
              'gate has reset. Clearing it is the whole point.');
      expect(prefs.getBool(SecureSettingsStore.freshInstallMarkerKey), isTrue,
          reason: 'Without the marker this is re-decided on every launch, and '
              'the app could never keep a credential at all.');
    });

    test('adopts an install that has run before, without touching the store',
        () async {
      SharedPreferences.setMockInitialValues(
          {AppConstants.termsAcceptedKey: AppConstants.termsVersion});
      final prefs = await SharedPreferences.getInstance();
      final storage = _RecordingStorage();

      final wiped = await SecureSettingsStore(storage).reconcileInstall(prefs);

      expect(wiped, isFalse);
      expect(storage.deleteAllCalls, 0,
          reason: 'This is the upgrade case. The marker did not exist before '
              'the build that added it, so it is absent for every existing '
              'install on that build\'s first launch — and preferences '
              'survive an in-place update. Wiping here destroys every '
              'credential the user has.');
      expect(prefs.getBool(SecureSettingsStore.freshInstallMarkerKey), isTrue,
          reason: 'The decision must still be recorded, or it is re-made from '
              'scratch every launch.');
    });

    test('does nothing once the decision has been recorded', () async {
      SharedPreferences.setMockInitialValues(
          {SecureSettingsStore.freshInstallMarkerKey: true});
      final storage = _RecordingStorage();

      final wiped = await SecureSettingsStore(storage)
          .reconcileInstall(await SharedPreferences.getInstance());

      expect(wiped, isFalse);
      expect(storage.deleteAllCalls, 0);
    });

    test('a keychain that will not clear does not stop the app launching',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();

      await expectLater(
        SecureSettingsStore(_ThrowingStorage()).reconcileInstall(prefs),
        completion(isFalse),
        reason: 'This runs before runApp. Throwing here would turn a keychain '
            'problem into an app that does not start.',
      );
      expect(prefs.getBool(SecureSettingsStore.freshInstallMarkerKey), isTrue,
          reason: 'A failed wipe must still record the decision. Retrying it '
              'next launch would let a transient keychain error delete '
              'whatever the user entered in between, over and over.');
    });

    test('a keychain that hangs is bounded by wipeTimeout', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();

      await expectLater(
        SecureSettingsStore(_HangingStorage()).reconcileInstall(prefs),
        completion(isFalse),
        reason: 'deleteAll crosses a platform channel, and a channel with no '
            'handler never answers rather than failing — so the bound is the '
            'only thing that returns control to main().',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/// Records deleteAll(), readAll() and delete(); everything else is unused by
/// these tests.
class _RecordingStorage extends FlutterSecureStorage {
  _RecordingStorage() : super();
  int deleteAllCalls = 0;
  int readAllCalls = 0;
  final List<String> deleteCalls = [];

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      deleteCalls.add(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readAllCalls++;
    return <String, String>{};
  }

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

/// Never answers, like an unregistered platform channel.
class _HangingStorage extends FlutterSecureStorage {
  _HangingStorage() : super();

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      Completer<void>().future;
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
