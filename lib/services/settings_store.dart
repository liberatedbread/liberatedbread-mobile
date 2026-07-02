// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// Minimal key/value persistence for app settings and secrets.
///
/// The production implementation ([SecureSettingsStore]) uses the platform
/// keychain/keystore via flutter_secure_storage. Wrapping it behind this
/// interface keeps unit and widget tests off the platform channels - tests
/// inject an in-memory fake through the Riverpod provider instead.
abstract class SettingsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
