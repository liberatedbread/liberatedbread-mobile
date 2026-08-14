// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'settings_store.dart';

/// The per-device user key a Rabbit Air purifier's LAN protocol encrypts
/// under, remembered per device.
///
/// The key is a 16-byte AES key the device generated itself, revealed to the
/// owner through the vendor app (device page → Rename → tap the device name)
/// as a 32-hex-character string. It is a long-lived LAN secret — the Hue
/// whitelist username's peer — so it lives in the platform keychain via
/// [SettingsStore], never in plain preferences, never logged.
///
/// Keyed by the device's stable identity — the Thing ID, which IS its mDNS
/// hostname — and never by IP alone, because the IP is a DHCP lease. A caller
/// without a hostname falls back to the host, which strands the key if DHCP
/// reassigns; that is a re-prompt, not a leak onto another device.
class RabbitAirKeyStore {
  final SettingsStore _store;

  RabbitAirKeyStore(this._store);

  /// `rabbitair.<THING-ID>.userkey`, matching the `hub.hue.<BRIDGEID>.*`
  /// namespacing the hub credential store uses.
  static String _key(String deviceId) => 'rabbitair.$deviceId.userkey';

  /// Whether [key] is the documented shape: exactly 32 hex characters (16
  /// raw bytes). Checked at entry time so a typo is a dialog error, not a
  /// device that never answers.
  static bool isValidUserKey(String key) =>
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(key.trim());

  Future<String?> userKey(String deviceId) => _store.read(_key(deviceId));

  Future<void> saveUserKey(String deviceId, String key) =>
      _store.write(_key(deviceId), key.trim().toLowerCase());

  /// Forget the key — e.g. after the device was factory-reset and
  /// reprovisioned, which mints a fresh one.
  Future<void> forget(String deviceId) => _store.delete(_key(deviceId));
}
