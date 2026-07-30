// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  // iOS: first_unlock keeps the keychain items readable after the
  // first post-boot unlock, including while the app runs in the
  // background — the sensor forwarder needs to read the token/webhook
  // id then. (The default `unlocked` would block background reads
  // whenever the device is locked.) These items are not synced to
  // other devices, matching a per-install registration.
  static const IOSOptions iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

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
}
