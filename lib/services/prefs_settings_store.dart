// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_store.dart';

/// [SettingsStore] backed by [SharedPreferences], for NON-secret preferences
/// such as the spec-pack source URL. Secrets belong in [SecureSettingsStore]
/// instead — this store writes to plain platform preferences.
class PrefsSettingsStore implements SettingsStore {
  final SharedPreferences _prefs;

  PrefsSettingsStore(this._prefs);

  @override
  Future<String?> read(String key) async => _prefs.getString(key);

  @override
  Future<void> write(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> delete(String key) => _prefs.remove(key);

  @override
  Future<Map<String, String>> readAll() async => {
        for (final key in _prefs.getKeys())
          if (_prefs.getString(key) case final String value) key: value,
      };
}
