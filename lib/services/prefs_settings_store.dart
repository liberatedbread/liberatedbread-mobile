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

  /// Every STRING preference, which is all this interface can express.
  ///
  /// Reads each key with the untyped [SharedPreferences.get], not
  /// `getString`: the preference file is shared with the rest of the app and
  /// is full of non-strings — the terms-accepted flag, the fresh-install
  /// marker, the saved panel sizes — and `getString` is `_cache[key] as
  /// String?`, which THROWS a `TypeError` on the first one it meets rather
  /// than returning null. So the comprehension's `case final String` guard
  /// never got the chance to skip anything: in production readAll() threw
  /// before it could filter, and every enumerating caller
  /// (DeviceCredentialStore.credentials(), the Rabbit Air candidate keys,
  /// "forget this device") failed with it. Tests missed it because a store
  /// built over `setMockInitialValues({})` holds only what the test wrote.
  @override
  Future<Map<String, String>> readAll() async => {
    for (final key in _prefs.getKeys())
      if (_prefs.get(key) case final String value) key: value,
  };
}
