// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings_store.dart';

/// [SettingsStore] backed by the platform keychain/keystore. The Home
/// Assistant long-lived token and webhook id are secrets, so everything HA
/// lives here rather than in plain preferences.
class SecureSettingsStore implements SettingsStore {
  final FlutterSecureStorage _storage;

  SecureSettingsStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
