// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'settings_store.dart';

/// What the link-button pairing issued for one bridge.
class HubCredentials {
  /// The whitelist username every authenticated request path embeds. A
  /// long-lived LAN secret: never logged, never keyed by IP.
  final String username;

  /// The 16-byte Entertainment DTLS PSK, hex — only obtainable at creation
  /// time, so it is stored even though nothing drives Entertainment yet.
  final String? clientKey;

  const HubCredentials({required this.username, this.clientKey});
}

/// Everything the app remembers about one paired hub, keyed by the hub's
/// stable identity — for a Hue bridge, the bridgeid.
///
/// Keyed by bridgeid and never by IP, because the IP is a DHCP lease and the
/// bridgeid is the device: the spec's rejoin note says a bridge moved to a
/// new router keeps its whitelist, and this store is what makes the app
/// agree. Backed by [SettingsStore], so production writes land in the
/// platform keychain and tests inject an in-memory fake.
class HubCredentialStore {
  final SettingsStore _store;

  HubCredentialStore(this._store);

  /// `hub.hue.<BRIDGEID>.<field>`. The bridgeid is uppercased on the way in
  /// because the two places it arrives from disagree: mDNS TXT spells it
  /// uppercase, the TLS certificate CN lowercase, and a store keyed by
  /// whichever arrived first would strand the credential.
  static String _key(String bridgeId, String field) =>
      'hub.hue.${bridgeId.toUpperCase()}.$field';

  Future<HubCredentials?> credentials(String bridgeId) async {
    final username = await _store.read(_key(bridgeId, 'username'));
    if (username == null || username.isEmpty) return null;
    return HubCredentials(
      username: username,
      clientKey: await _store.read(_key(bridgeId, 'clientkey')),
    );
  }

  Future<void> saveCredentials(
    String bridgeId,
    HubCredentials credentials,
  ) async {
    await _store.write(_key(bridgeId, 'username'), credentials.username);
    final clientKey = credentials.clientKey;
    if (clientKey != null && clientKey.isNotEmpty) {
      await _store.write(_key(bridgeId, 'clientkey'), clientKey);
    }
  }

  /// The pinned TLS leaf, as lowercase hex sha256 of the certificate DER.
  Future<String?> certPin(String bridgeId) =>
      _store.read(_key(bridgeId, 'cert_sha256'));

  Future<void> saveCertPin(String bridgeId, String sha256Hex) =>
      _store.write(_key(bridgeId, 'cert_sha256'), sha256Hex.toLowerCase());

  /// Which scheme reached this bridge last: `https`, or `http` for a BSB001
  /// (or old firmware) with no 443 at all. Absent means undecided — the
  /// client probes HTTPS first.
  Future<String?> scheme(String bridgeId) =>
      _store.read(_key(bridgeId, 'scheme'));

  Future<void> saveScheme(String bridgeId, String scheme) =>
      _store.write(_key(bridgeId, 'scheme'), scheme);

  /// Unpair: forget everything about this bridge — credential, clientkey,
  /// TLS pin and scheme. The whitelist entry on the bridge itself survives
  /// (deleting it needs the credential being thrown away); re-pairing mints
  /// a fresh one.
  Future<void> forget(String bridgeId) async {
    for (final field in const [
      'username',
      'clientkey',
      'cert_sha256',
      'scheme',
    ]) {
      await _store.delete(_key(bridgeId, field));
    }
  }
}
