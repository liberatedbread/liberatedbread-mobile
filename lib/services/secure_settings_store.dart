// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/log.dart';

import 'settings_store.dart';

/// [SettingsStore] backed by the platform keychain/keystore. The Home
/// Assistant long-lived token and webhook id are secrets, so everything HA
/// lives here rather than in plain preferences.
class SecureSettingsStore implements SettingsStore {
  final FlutterSecureStorage _storage;

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

  // iOS: first_unlock_THIS_DEVICE.
  //
  // `first_unlock` (not `unlocked`) because the items must stay readable
  // while the app runs in the background after the first post-boot unlock —
  // the sensor forwarder reads the token and webhook id then, and `unlocked`
  // would fail every one of those reads on a locked phone.
  //
  // `_this_device` because the plain class is included in encrypted
  // iTunes/Finder and iCloud backups and RESTORED ONTO A DIFFERENT DEVICE.
  // The comment here used to claim these items matched "a per-install
  // registration"; they did not. A Home Assistant long-lived token, a Hue
  // username and client key, a Roomba local password, a Rabbit Air AES key
  // and the TLS trust-on-first-use pins are all device-scoped secrets for
  // hardware on one particular LAN, and none of them should ride a backup
  // onto a second phone.
  //
  // Note this is only half the story: iOS does not delete keychain items when
  // an app is uninstalled either, so a reinstall used to silently inherit
  // every credential while the Terms gate — which reads SharedPreferences,
  // and IS cleared on uninstall — reset to first-run. `wipeIfFreshInstall`
  // below closes that half.
  static const IOSOptions iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  /// Marker key proving this install has run before.
  ///
  /// Lives in SharedPreferences ON PURPOSE: prefs are removed with the app,
  /// the keychain is not, and the difference between them is exactly the
  /// signal "these credentials outlived their install".
  static const String freshInstallMarkerKey = 'secure_store_install_marker';

  SecureSettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: androidOptions,
              iOptions: iosOptions,
            );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  /// Clear the keychain when this is a fresh install of the app.
  ///
  /// The iOS keychain survives app deletion, so without this a user who
  /// deletes the app and installs it again gets the first-run Terms gate
  /// (SharedPreferences having been cleared) on top of a store still holding
  /// their Home Assistant token, Hue credentials, Roomba password and TLS
  /// pins. That is a surprise in the wrong direction: the app presents itself
  /// as new while remembering secrets the user believed they had removed, and
  /// re-adopting a device silently reuses a stale pin.
  ///
  /// [hasRun] / [markRun] read and write the marker; the caller supplies them
  /// so this stays free of a SharedPreferences dependency and is testable
  /// without one. Returns true when a wipe happened.
  ///
  /// Deliberately best-effort: a keychain that cannot be cleared must not stop
  /// the app launching, since the failure mode of throwing here is an app that
  /// will not start at all.
  /// A hung keychain must not become an app that never launches, so the wipe
  /// is bounded as well as caught. deleteAll() goes over a platform channel,
  /// and a channel with nothing on the other end (a widget test booting
  /// main(), a plugin that failed to register) does not fail — it simply never
  /// answers, which a try/catch cannot see.
  static const Duration wipeTimeout = Duration(seconds: 5);

  Future<bool> wipeIfFreshInstall({
    required Future<bool> Function() hasRun,
    required Future<void> Function() markRun,
  }) async {
    try {
      if (await hasRun()) return false;
      await _storage.deleteAll().timeout(wipeTimeout);
      await markRun();
      return true;
    } catch (error, stackTrace) {
      Log.app.warning(
        'could not clear the secure store on first run; continuing',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
