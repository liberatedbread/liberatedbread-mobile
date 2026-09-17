// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/log.dart';

import 'settings_store.dart';

/// [SettingsStore] backed by the platform keychain/keystore. The Home
/// Assistant long-lived token and webhook id are secrets, so everything HA
/// lives here rather than in plain preferences.
class SecureSettingsStore implements SettingsStore {
  final FlutterSecureStorage _storage;

  /// Used for the operations that must match EVERY item regardless of the
  /// accessibility class it was written under. See [iosOptionsAnyAccessibility].
  final FlutterSecureStorage _sweeping;

  // Android: we intentionally keep `encryptedSharedPreferences`
  // rather than flipping backends. flutter_secure_storage 9.x does
  // not auto-migrate between the EncryptedSharedPreferences backend
  // and the default keystore backend, so switching would silently
  // strand every already-stored value (the token/webhook id would
  // read back as null). That backend is a known read-failure source
  // (a rotated/invalidated key throws on read), so we pair it with
  // `resetOnError: true`: an entry that can no longer be decrypted is
  // dropped and read returns null instead of throwing. Valid entries
  // are untouched, so existing reads keep working while a corrupt one
  // self-heals into "not configured" and lets the user re-register.
  static const AndroidOptions androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: true,
  );

  // iOS: WRITE with first_unlock_THIS_DEVICE.
  //
  // `first_unlock` (not `unlocked`) because the items must stay readable
  // while the app runs in the background after the first post-boot unlock —
  // the sensor forwarder reads the token and webhook id then, and `unlocked`
  // would fail every one of those reads on a locked phone.
  //
  // `_this_device` because the plain class is included in encrypted
  // iTunes/Finder and iCloud backups and RESTORED ONTO A DIFFERENT DEVICE. A
  // Home Assistant long-lived token, a Hue username and client key, a Roomba
  // local password, a Rabbit Air AES key and the TLS trust-on-first-use pins
  // are all device-scoped secrets for hardware on one particular LAN, and
  // none of them should ride a backup onto a second phone.
  static const IOSOptions iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  // iOS: READ AND DELETE with no accessibility constraint at all.
  //
  // This is not a nicety, and getting it wrong is what made the first version
  // of this change destructive. On Apple platforms flutter_secure_storage puts
  // the accessibility class INTO THE KEYCHAIN QUERY
  // (ios/Classes/FlutterSecureStorage.swift, baseQuery: `if accessibility !=
  // nil { keychainQuery[kSecAttrAccessible] = ... }`), and readAll(), delete()
  // and deleteAll() all pass the instance's class while read(key:) hardcodes
  // nil. So a store configured with one class simply CANNOT SEE items written
  // under another: SecItemCopyMatching returns nothing and SecItemDelete
  // matches nothing, both of which look like success.
  //
  // Two consequences, both of which bit:
  //   * readAll() went blind the moment the write class changed. Every
  //     enumerating caller — DeviceCredentialStore.credentials(), the Rabbit
  //     Air candidate keys, "forget this device" — saw an empty map on any
  //     phone that had run an earlier build, so requests went out
  //     unauthenticated and forget left the item behind. Single-key read()
  //     kept working, which is exactly what made it look random.
  //   * wipeIfFreshInstall's deleteAll() could not delete the items it exists
  //     to delete, returned errSecItemNotFound (which the plugin maps to
  //     success), and wrote the marker anyway — logging that it had cleared
  //     credentials that were all still there.
  //
  // Dart's AppleOptions.toMap() omits the key entirely when accessibility is
  // null, so this really does produce an unconstrained query rather than a
  // defaulted one. Writes keep the stronger class above; anything already
  // stored under the old one stays readable and deletable, and migrates on its
  // next write (the plugin's write() deletes across classes before re-adding).
  // That means no migration pass is needed.
  static const IOSOptions iosOptionsAnyAccessibility =
      IOSOptions(accessibility: null);

  /// Marker key proving this install has run before.
  ///
  /// Lives in SharedPreferences ON PURPOSE: on iOS prefs are removed with the
  /// app and the keychain is not, and the difference between them is exactly
  /// the signal "these credentials outlived their install".
  ///
  /// Absence of this key is NOT on its own proof of a fresh install — see
  /// [isFreshInstall].
  static const String freshInstallMarkerKey = 'secure_store_install_marker';

  /// Whether this looks like a genuinely fresh install rather than an update.
  ///
  /// The marker was introduced after the app already had users, so on the
  /// first launch of the build that added it the key is absent for EVERY
  /// existing install — SharedPreferences survives an in-place update on every
  /// platform. Treating that as a fresh install wiped every credential the
  /// user had, unrecoverably, on upgrade. So absence of the marker only counts
  /// when there is no other evidence the app has run here before.
  ///
  /// [AppConstants.termsAcceptedKey] is the witness: the terms gate is
  /// unskippable, so anyone who has ever reached the app past first launch has
  /// it, and a real fresh install has neither key.
  static bool isFreshInstall(SharedPreferences prefs) =>
      !prefs.containsKey(freshInstallMarkerKey) &&
      !prefs.containsKey(AppConstants.termsAcceptedKey);

  SecureSettingsStore(
      [FlutterSecureStorage? storage, FlutterSecureStorage? sweeping])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: androidOptions,
              iOptions: iosOptions,
            ),
        // Falls back to the injected [storage] before the default, so a test
        // that supplies one fake still sees every call through it.
        _sweeping = sweeping ??
            storage ??
            const FlutterSecureStorage(
              aOptions: androidOptions,
              iOptions: iosOptionsAnyAccessibility,
            );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  // Through the sweeping store, like readAll and the wipe: the plugin's
  // delete(key) carries the instance's accessibility class in its query too,
  // so a class-scoped delete cannot remove an item an earlier build wrote —
  // "forget this device" would report success and leave the credential.
  @override
  Future<void> delete(String key) => _sweeping.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _sweeping.readAll();

  /// A hung keychain must not become an app that never launches, so the wipe
  /// is bounded as well as caught. deleteAll() goes over a platform channel,
  /// and a channel with no handler registered — a widget test that boots
  /// main(), a plugin that failed to register — does not fail. It simply never
  /// answers, which a try/catch cannot see.
  static const Duration wipeTimeout = Duration(seconds: 5);

  /// Settle, once per install, whether the keychain this app can see belongs
  /// to this install — and clear it if it does not.
  ///
  /// The iOS keychain survives app deletion while SharedPreferences does not,
  /// so without this a user who deletes the app and installs it again gets the
  /// first-run Terms gate sitting on top of a store that still holds their
  /// Home Assistant token, Hue credentials, Roomba password and TLS pins. The
  /// app presents itself as new while remembering secrets the user believed
  /// they had removed, and re-adopting a device silently reuses a stale pin.
  ///
  /// [freshInstallMarkerKey] records that this decision has been MADE, not
  /// that a wipe happened. Once it is present nothing here runs again, which
  /// is what stops a store that is briefly unavailable from being re-examined
  /// — and re-wiped — on every launch.
  ///
  /// Returns true when a wipe actually happened.
  ///
  /// Deliberately best-effort throughout: this runs before `runApp`, and a
  /// keychain that cannot be read or cleared must not become an app that will
  /// not start.
  Future<bool> reconcileInstall(SharedPreferences prefs) async {
    if (prefs.containsKey(freshInstallMarkerKey)) return false;

    // Absent marker, but the app has run here before (an update in place, or
    // the first launch of the build that introduced the marker). Adopt the
    // install: record the decision, touch nothing.
    if (!isFreshInstall(prefs)) {
      await _record(prefs);
      return false;
    }

    var wiped = false;
    try {
      // Through [_sweeping], NOT [_storage]: on Apple platforms a
      // class-scoped deleteAll silently matches nothing written under a
      // different class, which is precisely the case this exists for.
      await _sweeping.deleteAll().timeout(wipeTimeout);
      wiped = true;
    } catch (error, stackTrace) {
      Log.app.warning(
        'could not clear the secure store on first run; continuing',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Recorded even when the delete failed. The marker means the decision was
    // made; retrying it next launch would let a transient keychain error
    // delete whatever the user has entered in between, over and over. Stale
    // credentials left behind are the smaller harm.
    await _record(prefs);
    return wiped;
  }

  /// The wipe on its own, without the prefs bookkeeping.
  ///
  /// Exists for integration_test/keychain_accessibility_test.dart, which has
  /// to prove against a REAL keychain that the delete is not scoped to the
  /// current write class. Everything else goes through [reconcileInstall].
  @visibleForTesting
  Future<void> wipeForTest() => _sweeping.deleteAll();

  Future<void> _record(SharedPreferences prefs) async {
    try {
      await prefs.setBool(freshInstallMarkerKey, true);
    } catch (error, stackTrace) {
      Log.app.warning(
        'could not record the install marker; this will be re-decided on the '
        'next launch',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
