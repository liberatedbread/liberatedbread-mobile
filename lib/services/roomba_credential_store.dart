// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'settings_store.dart';

/// What a robot's password handshake — or its owner's iRobot account — yielded.
///
/// The password is long-lived in a way most device secrets are not: community
/// reports have it changing only on a factory reset, and there is no way to
/// revoke one without performing that reset. Anyone holding it has full local
/// control of the robot for as long as it lives. Treat it as a password, not
/// as a device id.
class RoombaCredentials {
  /// The robot's identity and its MQTT username.
  final String blid;

  /// The per-robot secret. Kept whole: Roomba passwords begin with `:` and
  /// contain `:` separators, and a client that trims or splits one sends a
  /// credential the broker refuses without saying why.
  final String password;

  /// The robot's own name, for display. Not identity — the owner can change it.
  final String? name;

  /// Model code (`R980020`). Recorded because it is the fastest way to tell a
  /// local-capable robot from a 2025 one when someone reports a problem.
  final String? sku;

  /// The address the robot last answered on. A convenience for reconnecting
  /// without a scan, never an identity — see [_key].
  final String? lastIp;

  /// Base URL of a [rest980](https://github.com/koalazak/rest980) server to
  /// route through instead of talking to the robot directly. Null — the
  /// default — means direct.
  ///
  /// Stored per robot rather than once for the app because a rest980 instance
  /// is configured for ONE robot: its BLID and password are baked into that
  /// container's environment. Two robots means two servers, and a single
  /// global setting would silently send one robot's commands to the other's.
  final String? rest980BaseUrl;

  const RoombaCredentials({
    required this.blid,
    required this.password,
    this.name,
    this.sku,
    this.lastIp,
    this.rest980BaseUrl,
  });

  /// Whether commands go through a rest980 server rather than straight at the
  /// robot.
  bool get usesRest980 => rest980BaseUrl != null && rest980BaseUrl!.isNotEmpty;

  RoombaCredentials copyWith({
    String? name,
    String? sku,
    String? lastIp,
    String? rest980BaseUrl,
  }) =>
      RoombaCredentials(
        blid: blid,
        password: password,
        name: name ?? this.name,
        sku: sku ?? this.sku,
        lastIp: lastIp ?? this.lastIp,
        rest980BaseUrl: rest980BaseUrl ?? this.rest980BaseUrl,
      );
}

/// Everything the app remembers about one adopted robot, keyed by its BLID.
///
/// The sibling of [HubCredentialStore] for the MQTT transport, and keyed the
/// same way and for the same reason: **by BLID, never by IP**. The IP is a
/// DHCP lease and changes without warning; the BLID is the robot and survives
/// a router replacement, a re-scan, and the robot moving house. A store keyed
/// on the address would strand the credential the first time the lease
/// rotated, and the owner would have to redo the button handshake to recover
/// something the app already had.
///
/// Backed by [SettingsStore], so production writes land in the platform
/// keychain/keystore and tests inject an in-memory fake.
class RoombaCredentialStore {
  final SettingsStore _store;

  RoombaCredentialStore(this._store);

  /// `roomba.<BLID>.<field>`. The BLID is uppercased on the way in because the
  /// two places it arrives from disagree: the UDP announcement's hostname
  /// spells it uppercase and iRobot's account API lowercase, and a store keyed
  /// by whichever arrived first would hide a credential the app already holds.
  static String _key(String blid, String field) =>
      'roomba.${blid.toUpperCase()}.$field';

  static const _fields = [
    'password',
    'name',
    'sku',
    'last_ip',
    'rest980_base_url',
  ];

  Future<RoombaCredentials?> credentials(String blid) async {
    final password = await _store.read(_key(blid, 'password'));
    if (password == null || password.isEmpty) return null;
    return RoombaCredentials(
      blid: blid,
      password: password,
      name: await _store.read(_key(blid, 'name')),
      sku: await _store.read(_key(blid, 'sku')),
      lastIp: await _store.read(_key(blid, 'last_ip')),
      rest980BaseUrl: await _store.read(_key(blid, 'rest980_base_url')),
    );
  }

  Future<void> save(RoombaCredentials credentials) async {
    await _store.write(
        _key(credentials.blid, 'password'), credentials.password);
    await _writeIfPresent(credentials.blid, 'name', credentials.name);
    await _writeIfPresent(credentials.blid, 'sku', credentials.sku);
    await _writeIfPresent(credentials.blid, 'last_ip', credentials.lastIp);
    await _writeIfPresent(
      credentials.blid,
      'rest980_base_url',
      credentials.rest980BaseUrl,
    );
  }

  /// Point this robot at a rest980 server, or clear it back to direct control.
  ///
  /// A separate setter rather than a [save] round trip because it is a toggle
  /// the settings UI flips on its own, and reading-then-writing the whole
  /// record to change one field is how a password gets clobbered by a screen
  /// that never had one.
  Future<void> setRest980BaseUrl(String blid, String? baseUrl) async {
    final key = _key(blid, 'rest980_base_url');
    if (baseUrl == null || baseUrl.isEmpty) {
      await _store.delete(key);
      return;
    }
    await _store.write(key, baseUrl);
  }

  /// Remember where the robot answered last, so a later session can reconnect
  /// without waiting on a broadcast that a VLAN may not carry.
  Future<void> rememberAddress(String blid, String ip) =>
      _store.write(_key(blid, 'last_ip'), ip);

  Future<void> _writeIfPresent(String blid, String field, String? value) async {
    if (value == null || value.isEmpty) return;
    await _store.write(_key(blid, field), value);
  }

  /// Forget a robot entirely.
  ///
  /// Nothing changes on the robot itself: unlike a Hue whitelist entry there is
  /// no credential to revoke, and the same password keeps working for anyone
  /// who still has it. Only a factory reset mints a new one — which is worth
  /// saying out loud to anyone selling a robot on.
  Future<void> forget(String blid) async {
    for (final field in _fields) {
      await _store.delete(_key(blid, field));
    }
  }
}
