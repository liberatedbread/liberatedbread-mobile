// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:liberated_bread_mobile/services/settings_store.dart';

/// Map-backed [SettingsStore] so tests never touch the platform keychain.
class InMemorySettingsStore implements SettingsStore {
  final Map<String, String> values;

  InMemorySettingsStore([Map<String, String>? initial])
      : values = {...?initial};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
